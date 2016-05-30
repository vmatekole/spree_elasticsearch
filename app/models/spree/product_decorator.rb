module Spree
  Classification.class_eval do
    include Elasticsearch::Model
    index_name Spree::ElasticsearchSettings.index
    document_type 'spree_products_taxons'

    mapping _parent: {type: 'spree_product'} do
      indexes :position, type: 'integer'
      indexes :taxon_id, type: 'integer'
    end

    def as_indexed_json(options={})
      {taxon_id: taxon.id, position: position}.to_json
    end
  end

  Product.class_eval do
    include Elasticsearch::Model
    index_name Spree::ElasticsearchSettings.index
    document_type 'spree_product'
    mapping _all: { analyzer: 'nGram_analyzer', search_analyzer: 'nGram_analyzer' } do
      indexes :name, type: 'multi_field' do
        indexes :name, type: 'string', analyzer: 'snowball'
        indexes :untouched, type: 'string', include_in_all: false, index: 'not_analyzed'
      end

      indexes :description, type: 'string', analyzer: 'snowball'
      indexes :taxon_names, type: 'string', analyzer: 'snowball'
      indexes :available_on, type: 'date', format: 'dateOptionalTime', include_in_all: false
      indexes :price, type: 'double'
      indexes :sku, type: 'string', index: 'not_analyzed'
      indexes :slug, type: 'string', index: 'not_analyzed'
      indexes :taxon_ids, type: 'string', index: 'not_analyzed'
      indexes :properties, type: 'string', index: 'not_analyzed'
    end

    mapping do
      indexes :name_suggest, type: 'completion', payloads:true
    end

    def taxon_names
      taxons.map(&:self_and_ancestors).flatten.uniq.map(&:name).join(',') unless taxons.empty?
    end

    def taxon_info(taxon_ids)
      return unless taxon_ids
      taxons = Spree::Taxon.find(taxon_ids)
      taxons = taxons.select{|t|t.depth == 1}
      return unless taxons.any?
      result = []
      taxons.select(&:visible).select{|t|t.taxonomy.name.downcase != :meta}.each do |t|
        c = {}
        permalink = t.permalink || ''
        next if  permalink.blank?
        if permalink = t.permalink.split('/').second
          c[:permalink] = permalink
          c[:id] = t.id
          result.push(c)
        end
      end
      result
    end

    def tokenize_name(name)
      single_words = name.split(/[\W+\s+\b]/)
      concat_word = single_words[0] + " "
      input = single_words.clone
      single_words.each_with_index do |n,i|
        if i < single_words.length - 1
          input.push(concat_word.clone)
          concat_word.concat(single_words[i + 1]).concat(" ")
        end
      end
      input
    end

    def as_indexed_json(options={})
        result = as_json({
        methods: [:price,:sku,:taxon_names],
        only: [:available_on, :description, :name],
        include: {
          variants: {
            only: [:sku],
            include: {
              option_values: {
                only: [:name, :description,:presentation],
                methods: [:taxon_name]

              }
            }
          }
        }
      })
      result[:price] = price
      result[:slug] = slug
      result[:clp_image_url] = image_url(:clp_small)
      result[:hover_image_url] = hover_image_url
      result[:properties] = property_list unless property_list.empty?
      result[:taxon_ids] = taxons.map(&:self_and_ancestors).flatten.uniq.map(&:id) unless taxons.empty?
      keywords = meta_keywords.split(/[\W+\s+\b]/) if meta_keywords
      taxons  = taxon_info(result[:taxon_ids])

      if taxons and taxons.any?  # we only index products with taxons associated
        result[:name_suggest] = {
              input: tokenize_name(name).append(keywords),
              output: name,
              payload: {
                suggest: {
                  id: id,
                  name: name,
                  available_on: available_on,
                  image: image_url(:micro),
                  taxons: taxons.map{|i| {name: i[:permalink], id: i[:id]}}
                }
              }
        }
      end
      result
    end

    def self.get(product_id)
      Elasticsearch::Model::Response::Result.new(__elasticsearch__.client.get index: index_name, type: document_type, id: product_id)
    end

    # Inner class used to query elasticsearch. The idea is that the query is dynamically build based on the parameters.
    class Product::ElasticsearchQuery
      include ::Virtus.model

      attribute :from, Integer, default: 0
      attribute :price_min, Float
      attribute :price_max, Float
      attribute :properties, Hash
      attribute :query, String
      attribute :root_taxon_ids, Array
      attribute :taxons, Array
      attribute :size, Integer
      attribute :browse_mode, Boolean
      attribute :available_by_max_no_days, Integer
      attribute :sorting, String

      # When browse_mode is enabled, the taxon filter is placed at top level. This causes the results to be limited, but facetting is done on the complete dataset.
      # When browse_mode is disabled, the taxon filter is placed inside the filtered query. This causes the aggregations to be limited to the resulting set.

      # Method that creates the actual query based on the current attributes.
      # The idea is to always to use the following schema and fill in the blanks.
      # {
      #   query: {
      #     filtered: {
      #       query: {
      #         query_string: { query: , fields: [] }
      #       }
      #       filter: {
      #         and: [
      #           { terms: { taxons: [] } },
      #           { terms: { properties: [] } }
      #         ]
      #       }
      #     }
      #   }
      #   filter: { range: { price: { lte: , gte: } } },
      #   sort: [],
      #   from: ,
      #   aggregations:
      # }
      def to_hash
        q = { match_all: {} }
        unless query.blank? # nil or empty
          q = { query_string: { query: query, fields: ['name^5','description','sku', 'taxon_names'], default_operator: 'AND', use_dis_max: true } }
        end
        query = q

        and_filter = []
        unless @properties.nil? || @properties.empty?
          # transform properties from [{"key1" => ["value_a","value_b"]},{"key2" => ["value_a"]}
          # to { terms: { properties: ["key1||value_a","key1||value_b"] }
          #    { terms: { properties: ["key2||value_a"] }
          # This enforces "and" relation between different property values and "or" relation between same property values
          properties = @properties.map{ |key, value| [key].product(value) }.map do |pair|
            and_filter << { terms: { properties: pair.map { |property| property.join('||') } } }
          end
        end

        sorting = case @sorting
        when 'name_asc'
          [ { 'name.untouched' => { order: 'asc' } }, { price: { order: 'asc' } }, '_score' ]
        when 'name_desc'
          [ { 'name.untouched' => { order: 'desc' } }, { price: { order: 'asc' } }, '_score' ]
        when 'price_asc'
          [ { 'price' => { order: 'asc' } }, { 'name.untouched' => { order: 'asc' } }, '_score' ]
        when 'price_desc'
          [ { 'price' => { order: 'desc' } }, { 'name.untouched' => { order: 'asc' } }, '_score' ]
        when 'score'
          [ '_score', { 'name.untouched' => { order: 'asc' } }, { price: { order: 'asc' } } ]
        else
          [ { 'name.untouched' => { order: 'asc' } }, { price: { order: 'asc' } }, '_score' ]
        end

        # aggregations
        aggregations = {
          price: { stats: { field: 'price' } },
          properties: { terms: { field: 'properties', order: { _count: 'asc' }, size: 1000000 } },
          taxon_ids: { terms: { field: 'taxon_ids', size: 1000000 } }
        }

        # basic skeleton
        result = {
          min_score: 0.03,
          query: { filtered: {} },
          sort: sorting,
          from: from,
          aggregations: aggregations,
          size: size
        }

        # add query and filters to filtered
        result[:query][:filtered][:query] = query
        # taxon and property filters have an effect on the aggregations
        # and_filter << { terms: { taxon_ids: taxons } } unless taxons.empty?
        # only return products that are available
        #and_filter << { range: { available_on: { lte: "now" } }
        and_filter << { range: { available_on: { lte: 'now' } } }
        result[:query][:filtered][:filter] = { and: and_filter } unless and_filter.empty?
        and_filter << { terms: { taxon_ids: taxons } } if not taxons.empty?
        # only return products that are available
        result[:query][:filtered][:filter] = { and: and_filter } unless and_filter.empty?
        # add price filter outside the query because it should have no effect on aggregations
        # if price_min && price_max && (price_min < price_max)
        #   result[:filter] = { range: { price: { gte: price_min, lte: price_max } } }
        # end
        result
      end

      # def to_query_hash
      #   q = { match_all: {} }
      #   unless query.blank? # nil or empty
      #     q = { query_string: { query: query} }
      #   end
      #   query = q
      #
      #   and_filter = []
      #   unless @properties.nil? || @properties.empty?
      #     # transform properties from [{"key1" => ["value_a","value_b"]},{"key2" => ["value_a"]}
      #     # to { terms: { properties: ["key1||value_a","key1||value_b"] }
      #     #    { terms: { properties: ["key2||value_a"] }
      #     # This enforces "and" relation between different property values and "or" relation between same property values
      #     properties = @properties.map {|k,v| [k].product(v)}.map do |pair|
      #       and_filter << { terms: { properties: pair.map {|prop| prop.join("||")} } }
      #     end
      #   end
      #   sorting = case @sorting
      #   when "name_asc"
      #     [ {"name.untouched" => { order: "asc" }}, {"price" => { order: "asc" }}, "_score" ]
      #   when "name_desc"
      #     [ {"name.untouched" => { order: "desc" }}, {"price" => { order: "asc" }}, "_score" ]
      #   when "price_asc"
      #     [ {"price" => { order: "asc" }}, {"name.untouched" => { order: "asc" }}, "_score" ]
      #   when "price_desc"
      #     [ {"price" => { order: "desc" }}, {"name.untouched" => { order: "asc" }}, "_score" ]
      #   when "score"
      #     [ "_score", {"name.untouched" => { order: "asc" }}, {"price" => { order: "asc" }} ]
      #   else
      #     [ {"name.untouched" => { order: "asc" }}, {"price" => { order: "asc" }}, "_score" ]
      #   end
      #
      #   # aggregations
      #   aggregations = {
      #     price: { statistical: { field: "price" } },
      #     properties: { terms: { field: "properties", order: "count", size: 1000000 } },
      #     taxon_ids: { terms: { field: "taxon_ids", size: 1000000 } }
      #   }
      #
      #   # basic skeleton
      #   result = {
      #     min_score: 0.05,
      #     query: {filter:{}},
      #     sort: sorting,
      #     from: from,
      #     size: size,
      #     aggregations: aggregations
      #   }
      #
      #   # add query and filters to filtered
      #   result[:query] = query
      #   # taxon and property filters have an effect on the aggregations
      #   # and_filter << { terms: { taxon_ids: taxons } } if not taxons.empty?
      #   # Gift finder search
      #   # and_filter << { terms: { root_taxon_ids: @root_taxon_ids } } unless @root_taxon_ids.empty?
      #   # only return products that are available
      #   and_filter << { range: { available_on: { lte: Date.today } } }
      #
      #   result[:filter] = { "and" => and_filter } unless and_filter.empty?
      #
      #   # add price filter outside the query because it should have no effect on aggregations
      #   # if price_min && price_max && (price_min < price_max)
      #   #   result[:filter] = { range: { price: { gte: price_min, lte: price_max } } }
      #   # end
      #   result
      # end
    end

    def image_url(size)
      if images.size > 0
        return images.first.attachment.url(size)
      end
    end

    def hover_image_url
      image = images.find{|i| i.hover}
      image.attachment.url(:clp_small) if image
    end

    private

    def property_list
      product_properties.map{|pp| "#{pp.property.name}||#{pp.value}"}
    end
  end
end
