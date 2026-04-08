# frozen_string_literal: true

require_dependency "#{Rails.root}/lib/wiki_api"

#= Encapsulates MediaWiki API queries related to article/revision content.
#= This includes fetching revision metadata (IDs, parent IDs),
#= rendered HTML (action=parse), wikitext diffs (action=compare),
#= and revision history for a given page.
#=
#= Rather than constructing raw query hashes across the codebase,
#= callers use named methods that hide the MediaWiki parameter details
#= (rvprop, rvdir, prop: 'revisions', etc.).
class WikiApi
  class ArticleContent
    def initialize(wiki, update_service: nil)
      @wiki = wiki
      @wiki_api = WikiApi.new(@wiki, update_service)
    end

    # ---- Revision Metadata ----

    # Returns the latest revision ID for the article identified by +title+.
    # Example API call:
    #   action=query&prop=revisions&titles=Example&rvprop=ids
    def latest_revision_id(title)
      params = {
        action: 'query',
        prop: 'revisions',
        titles: title,
        rvprop: 'ids'
      }
      response = @wiki_api.query(params)
      page = response.data['pages']
      page_id = page.keys.first
      page.dig(page_id, 'revisions')&.first&.dig('revid')
    end

    # Returns the parent revision ID for a given +rev_id+.
    # Example API call:
    #   action=query&prop=revisions&revids=12345&rvprop=ids
    # Returns nil if the revision is missing/deleted.
    def parent_revision_id(rev_id)
      params = { prop: 'revisions', revids: rev_id, rvprop: 'ids' }
      resp = @wiki_api.query(params)

      if resp.data['badrevids'].present?
        Sentry.capture_message(
          "WikiApi::ArticleContent: revision #{rev_id} missing or deleted"
        )
        return nil
      end

      page_id = resp.data['pages'].keys.first
      resp.data.dig('pages', page_id, 'revisions')&.first&.dig('parentid')
    end

    # Returns parent revision IDs for a batch of +rev_ids+.
    # Used by RevisionScoreImporter.
    # Returns a hash { mw_rev_id => parent_id_string } or nil on failure.
    def parent_revision_ids(rev_ids)
      return {} if rev_ids.blank?
      params = { prop: 'revisions', revids: rev_ids, rvprop: 'ids' }
      response = @wiki_api.query(params)
      return unless response.present? && response.data['pages']

      revisions = {}
      response.data['pages'].each do |_page_id, page_data|
        rev_data = page_data['revisions']
        next unless rev_data
        rev_data.each do |rev_datum|
          mw_rev_id = rev_datum['revid']
          parent_id = rev_datum['parentid']
          next if parent_id.zero?
          revisions[mw_rev_id] = parent_id.to_s
        end
      end
      revisions
    end

    # ---- Rendered HTML (action=parse) ----

    # Returns the HTML rendering and metadata for a specific revision.
    # Example API call:
    #   action=parse&oldid=12345
    # Returns a hash: { html:, title:, page_id: }
    def revision_html(rev_id)
      params = { oldid: rev_id }
      resp = api_client.send('action', 'parse', params)
      {
        html: resp.data.dig('text', '*'),
        title: resp.data.dig('title'),
        page_id: resp.data.dig('pageid')
      }
    end

    # Parses raw wikitext into HTML.
    # Example API call:
    #   action=parse&text=...&contentmodel=wikitext
    # Returns the rendered HTML string.
    def parse_wikitext(wikitext)
      params = { text: wikitext, contentmodel: 'wikitext' }
      resp = api_client.send('action', 'parse', params)
      resp.data.dig('text', '*')
    end

    # ---- Diffs (action=compare) ----

    # Returns a diff table comparing two revisions.
    # Example API call:
    #   action=compare&fromrev=100&torev=200&difftype=table
    # Returns a hash: { diff_html:, title:, page_id: }
    def revision_diff(from_rev, to_rev)
      params = { torev: to_rev, fromrev: from_rev, difftype: 'table' }
      resp = api_client.send('action', 'compare', params)
      {
        diff_html: resp.data['*'],
        title: resp.data.dig('totitle'),
        page_id: resp.data.dig('toid')
      }
    end

    # ---- Revision History ----

    # Fetches revision history for a page within a date range.
    # Handles MediaWiki API continuation automatically across multiple requests.
    # +page_id+: MediaWiki page ID
    # +start_date+: most recent date (rvstart, since rvdir='older')
    # +end_date+:   oldest date (rvend)
    # +limit+: max revisions per request (default 500)
    #
    # If a block is given, it is called with each batch of revisions.
    # If the block returns truthy, fetching stops immediately (early exit).
    # This mirrors the old per-batch short-circuit behavior in alert monitors.
    #
    # Example API call:
    #   action=query&prop=revisions&pageids=123
    #     &rvstart=20250101000000&rvend=20240101000000
    #     &rvdir=older&rvlimit=500
    #
    # Returns all revisions fetched so far as a flat array.
    def revision_history(page_id, start_date:, end_date:, limit: 500)
      query_params = {
        action: 'query',
        prop: 'revisions',
        pageids: page_id,
        rvstart: start_date.strftime('%Y%m%d%H%M%S'),
        rvend: end_date.strftime('%Y%m%d%H%M%S'),
        rvdir: 'older',
        rvlimit: limit
      }

      all_revisions = []
      loop do
        response = @wiki_api.query(query_params)
        return all_revisions unless response

        revisions = response.data.dig('pages', page_id.to_s, 'revisions')
        if revisions.present?
          all_revisions.concat(revisions)
          # If a block is given to check each batch, stop as soon as it matches.
          # This avoids unnecessary API calls when the caller only needs to know
          # whether *any* matching revision exists (e.g. alert monitors).
          break if block_given? && yield(revisions)
        end

        cont = response['continue']
        break unless cont
        query_params['rvcontinue'] = cont['rvcontinue']
      end

      all_revisions
    end

    private

    def api_client
      @wiki_api.send(:api_client)
    end
  end
end
