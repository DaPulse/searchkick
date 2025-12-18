module Searchkick
  module IndexOptions
    def index_options
      options = @options
      language = options[:language]
      language = language.call if language.respond_to?(:call)

      below60 = Searchkick.server_below?("6.0.0")

      if options[:mappings] && !options[:merge_mappings]
        settings = options[:settings] || {}
        mappings = options[:mappings]
        # Remove include_in_all for ES 6.0+ (not allowed)
        unless below60
          mappings = remove_include_in_all(mappings)
        end
      else
        below22 = Searchkick.server_below?("2.2.0")
        below50 = Searchkick.server_below?("5.0.0-alpha1")
        default_type = below50 ? "string" : "text"
        index_false = below60 ? "no" : false
        index_true = below60 ? "analyzed" : true
        default_analyzer = below50 ? :default_index : :default
        keyword_mapping =
          if below50
            {
              type: default_type,
              index: "not_analyzed"
            }
          else
            {
              type: "keyword"
            }
          end

        keyword_mapping[:ignore_above] = (options[:ignore_above] || 256) unless below22

        settings = {
          analysis: {
            analyzer: {
              searchkick_keyword: {
                type: "custom",
                tokenizer: "keyword",
                filter: ["lowercase"] + (options[:stem_conversions] == false ? [] : ["searchkick_stemmer"])
              },
              default_analyzer => {
                type: "custom",
                # character filters -> tokenizer -> token filters
                # https://www.elastic.co/guide/en/elasticsearch/guide/current/analysis-intro.html
                char_filter: ["ampersand"],
                tokenizer: "standard",
                # synonym should come last, after stemming and shingle
                # shingle must come before searchkick_stemmer
                filter: ["standard", "lowercase", "asciifolding", "searchkick_index_shingle", "searchkick_stemmer"]
              },
              searchkick_search: {
                type: "custom",
                char_filter: ["ampersand"],
                tokenizer: "standard",
                filter: ["standard", "lowercase", "asciifolding", "searchkick_search_shingle", "searchkick_stemmer"]
              },
              searchkick_search2: {
                type: "custom",
                char_filter: ["ampersand"],
                tokenizer: "standard",
                filter: ["standard", "lowercase", "asciifolding", "searchkick_stemmer"]
              },
              # https://github.com/leschenko/elasticsearch_autocomplete/blob/master/lib/elasticsearch_autocomplete/analyzers.rb
              searchkick_autocomplete_index: {
                type: "custom",
                tokenizer: "searchkick_autocomplete_ngram",
                filter: ["lowercase", "asciifolding"]
              },
              searchkick_autocomplete_search: {
                type: "custom",
                tokenizer: "keyword",
                filter: ["lowercase", "asciifolding"]
              },
              searchkick_word_search: {
                type: "custom",
                tokenizer: "standard",
                filter: ["lowercase", "asciifolding"]
              },
              searchkick_suggest_index: {
                type: "custom",
                tokenizer: "standard",
                filter: ["lowercase", "asciifolding", "searchkick_suggest_shingle"]
              },
              searchkick_text_start_index: {
                type: "custom",
                tokenizer: "keyword",
                filter: ["lowercase", "asciifolding", "searchkick_edge_ngram"]
              },
              searchkick_text_middle_index: {
                type: "custom",
                tokenizer: "keyword",
                filter: ["lowercase", "asciifolding", "searchkick_ngram"]
              },
              searchkick_text_end_index: {
                type: "custom",
                tokenizer: "keyword",
                filter: ["lowercase", "asciifolding", "reverse", "searchkick_edge_ngram", "reverse"]
              },
              searchkick_word_start_index: {
                type: "custom",
                tokenizer: "standard",
                filter: ["lowercase", "asciifolding", "searchkick_edge_ngram"]
              },
              searchkick_word_middle_index: {
                type: "custom",
                tokenizer: "standard",
                filter: ["lowercase", "asciifolding", "searchkick_ngram"]
              },
              searchkick_word_end_index: {
                type: "custom",
                tokenizer: "standard",
                filter: ["lowercase", "asciifolding", "reverse", "searchkick_edge_ngram", "reverse"]
              }
            },
            filter: {
              searchkick_index_shingle: {
                type: "shingle",
                token_separator: ""
              },
              # lucky find http://web.archiveorange.com/archive/v/AAfXfQ17f57FcRINsof7
              searchkick_search_shingle: {
                type: "shingle",
                token_separator: "",
                output_unigrams: false,
                output_unigrams_if_no_shingles: true
              },
              searchkick_suggest_shingle: {
                type: "shingle",
                max_shingle_size: 5
              },
              searchkick_edge_ngram: {
                type: "edgeNGram",
                min_gram: 1,
                max_gram: 50
              },
              searchkick_ngram: {
                type: "nGram",
                min_gram: 1,
                max_gram: 50
              },
              searchkick_stemmer: {
                # use stemmer if language is lowercase, snowball otherwise
                # TODO deprecate language option in favor of stemmer
                type: language == language.to_s.downcase ? "stemmer" : "snowball",
                language: language || "English"
              }
            },
            char_filter: {
              # https://www.elastic.co/guide/en/elasticsearch/guide/current/custom-analyzers.html
              # &_to_and
              ampersand: {
                type: "mapping",
                mappings: ["&=> and "]
              }
            },
            tokenizer: {
              searchkick_autocomplete_ngram: {
                type: "edgeNGram",
                min_gram: 1,
                max_gram: 50
              }
            }
          }
        }

        if Searchkick.env == "test"
          settings[:number_of_shards] = 1
          settings[:number_of_replicas] = 0
        end

        if options[:similarity]
          settings[:similarity] = {default: {type: options[:similarity]}}
        end

        settings.deep_merge!(options[:settings] || {})

        # synonyms
        synonyms = options[:synonyms] || []

        synonyms = synonyms.call if synonyms.respond_to?(:call)

        if synonyms.any?
          settings[:analysis][:filter][:searchkick_synonym] = {
            type: "synonym",
            synonyms: synonyms.select { |s| s.size > 1 }.map { |s| s.is_a?(Array) ? s.join(",") : s }
          }
          # choosing a place for the synonym filter when stemming is not easy
          # https://groups.google.com/forum/#!topic/elasticsearch/p7qcQlgHdB8
          # TODO use a snowball stemmer on synonyms when creating the token filter

          # http://elasticsearch-users.115913.n3.nabble.com/synonym-multi-words-search-td4030811.html
          # I find the following approach effective if you are doing multi-word synonyms (synonym phrases):
          # - Only apply the synonym expansion at index time
          # - Don't have the synonym filter applied search
          # - Use directional synonyms where appropriate. You want to make sure that you're not injecting terms that are too general.
          settings[:analysis][:analyzer][default_analyzer][:filter].insert(4, "searchkick_synonym")
          settings[:analysis][:analyzer][default_analyzer][:filter] << "searchkick_synonym"

          %w(word_start word_middle word_end).each do |type|
            settings[:analysis][:analyzer]["searchkick_#{type}_index".to_sym][:filter].insert(2, "searchkick_synonym")
          end
        end

        if options[:wordnet]
          settings[:analysis][:filter][:searchkick_wordnet] = {
            type: "synonym",
            format: "wordnet",
            synonyms_path: Searchkick.wordnet_path
          }

          settings[:analysis][:analyzer][default_analyzer][:filter].insert(4, "searchkick_wordnet")
          settings[:analysis][:analyzer][default_analyzer][:filter] << "searchkick_wordnet"

          %w(word_start word_middle word_end).each do |type|
            settings[:analysis][:analyzer]["searchkick_#{type}_index".to_sym][:filter].insert(2, "searchkick_wordnet")
          end
        end

        if options[:special_characters] == false
          settings[:analysis][:analyzer].each do |_, analyzer_settings|
            analyzer_settings[:filter].reject! { |f| f == "asciifolding" }
          end
        end

        mapping = {}

        # conversions
        Array(options[:conversions]).each do |conversions_field|
          mapping[conversions_field] = {
            type: "nested",
            properties: {
              query: {type: default_type, analyzer: "searchkick_keyword"},
              count: {type: "integer"}
            }
          }
        end

        mapping_options = Hash[
          [:autocomplete, :suggest, :word, :text_start, :text_middle, :text_end, :word_start, :word_middle, :word_end, :highlight, :searchable, :filterable, :only_analyzed]
            .map { |type| [type, (options[type] || []).map(&:to_s)] }
        ]

        word = options[:word] != false && (!options[:match] || options[:match] == :word)

        mapping_options.values.flatten.uniq.each do |field|
          fields = {}

          if mapping_options[:only_analyzed].include?(field) || (options.key?(:filterable) && !mapping_options[:filterable].include?(field))
            fields[field] = {type: default_type, index: index_false}
          else
            fields[field] = keyword_mapping
          end

          if !options[:searchable] || mapping_options[:searchable].include?(field)
            if word
              fields["analyzed"] = {type: default_type, index: index_true, analyzer: default_analyzer}

              if mapping_options[:highlight].include?(field)
                fields["analyzed"][:term_vector] = "with_positions_offsets"
              end
            end

            mapping_options.except(:highlight, :searchable, :filterable, :only_analyzed, :word).each do |type, f|
              if options[:match] == type || f.include?(field)
                fields[type] = {type: default_type, index: index_true, analyzer: "searchkick_#{type}_index"}
              end
            end
          end

          mapping[field] =
            if below50
              {
                type: "multi_field",
                fields: fields
              }
            elsif fields[field]
              fields[field].merge(fields: fields.except(field))
            end
        end

        (options[:locations] || []).map(&:to_s).each do |field|
          mapping[field] = {
            type: "geo_point"
          }
        end

        options[:geo_shape] = options[:geo_shape].product([{}]).to_h if options[:geo_shape].is_a?(Array)
        (options[:geo_shape] || {}).each do |field, shape_options|
          mapping[field] = shape_options.merge(type: "geo_shape")
        end

        (options[:unsearchable] || []).map(&:to_s).each do |field|
          mapping[field] = {
            type: default_type,
            index: index_false
          }
        end

        routing = {}
        if options[:routing]
          routing = {required: true}
          unless options[:routing] == true
            routing[:path] = options[:routing].to_s
          end
        end

        dynamic_fields = {
          # analyzed field must be the default field for include_in_all
          # http://www.elasticsearch.org/guide/reference/mapping/multi-field-type/
          # however, we can include the not_analyzed field in _all
          # and the _all index analyzer will take care of it
          # include_in_all is not allowed in ES 6.0+
          "{name}" => below60 ? keyword_mapping.merge(include_in_all: !options[:searchable]) : keyword_mapping.dup
        }

        if options.key?(:filterable)
          dynamic_fields["{name}"] = {type: default_type, index: index_false}
        end

        dynamic_fields["{name}"][:ignore_above] = (options[:ignore_above] || 256) unless below22

        unless options[:searchable]
          if options[:match] && options[:match] != :word
            dynamic_fields[options[:match]] = {type: default_type, index: index_true, analyzer: "searchkick_#{options[:match]}_index"}
          end

          if word
            dynamic_fields["analyzed"] = {type: default_type, index: index_true}
          end
        end

        # http://www.elasticsearch.org/guide/reference/mapping/multi-field-type/
        multi_field =
          if below50
            {
              type: "multi_field",
              fields: dynamic_fields
            }
          else
            dynamic_fields["{name}"].merge(fields: dynamic_fields.except("{name}"))
          end

        # TODO make dynamic
        all_enabled = true

        default_mapping = {
          properties: mapping,
          _routing: routing,
          # https://gist.github.com/kimchy/2898285
          dynamic_templates: [
            {
              string_template: {
                match: "*",
                match_mapping_type: "string",
                mapping: multi_field
              }
            }
          ]
        }

        # _all field is deprecated in ES 6.0+
        if below60
          default_mapping[:_all] = all_enabled ? {type: default_type, index: index_true, analyzer: default_analyzer} : {enabled: false}
        end

        mappings = {
          _default_: default_mapping
        }.deep_merge(options[:mappings] || {})

        # Remove include_in_all for ES 6.0+ (not allowed)
        unless below60
          mappings = remove_include_in_all(mappings)
          # ES 6.0+ only allows one type per index - merge all types into _doc
          mappings = merge_types_for_es6(mappings)
        end
      end

      {
        settings: settings,
        mappings: mappings
      }
    end

    private

    # Recursively remove include_in_all from mappings (not allowed in ES 6.0+)
    def remove_include_in_all(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), result|
          next if k == :include_in_all || k == "include_in_all"
          result[k] = remove_include_in_all(v)
        end
      when Array
        obj.map { |item| remove_include_in_all(item) }
      else
        obj
      end
    end

    # ES 6.0+ only allows one type per index - merge all types into a single type
    def merge_types_for_es6(mappings)
      return mappings if mappings.nil? || mappings.empty?

      # Get all types except _default_
      types = mappings.keys.reject { |k| k == :_default_ || k == "_default_" }

      # If only one type (or none), just remove _default_ and return
      if types.size <= 1
        type_name = types.first || :_doc
        type_mapping = mappings[type_name] || mappings[:_default_] || mappings["_default_"] || {}

        # Merge _default_ settings into the type
        default_mapping = mappings[:_default_] || mappings["_default_"] || {}
        merged = deep_merge_mappings(default_mapping, type_mapping)

        # Remove _all from merged mapping (not allowed in ES 6.0+)
        merged.delete(:_all)
        merged.delete("_all")

        return { type_name => merged }
      end

      # Multiple types - merge all properties into single _doc type
      merged_properties = {}
      merged_dynamic_templates = []
      merged_other = {}

      # First, get _default_ as base
      default_mapping = mappings[:_default_] || mappings["_default_"] || {}
      if default_mapping[:properties] || default_mapping["properties"]
        merged_properties.merge!(default_mapping[:properties] || default_mapping["properties"] || {})
      end
      if default_mapping[:dynamic_templates] || default_mapping["dynamic_templates"]
        merged_dynamic_templates.concat(default_mapping[:dynamic_templates] || default_mapping["dynamic_templates"] || [])
      end

      # Merge all types
      types.each do |type_name|
        type_mapping = mappings[type_name] || {}
        if type_mapping[:properties] || type_mapping["properties"]
          merged_properties.merge!(type_mapping[:properties] || type_mapping["properties"] || {})
        end
        if type_mapping[:dynamic_templates] || type_mapping["dynamic_templates"]
          merged_dynamic_templates.concat(type_mapping[:dynamic_templates] || type_mapping["dynamic_templates"] || [])
        end
        # Collect other settings (like _routing)
        (type_mapping.keys - [:properties, "properties", :dynamic_templates, "dynamic_templates", :_all, "_all"]).each do |key|
          merged_other[key] = type_mapping[key]
        end
      end

      result = merged_other.merge({
        properties: merged_properties
      })
      result[:dynamic_templates] = merged_dynamic_templates unless merged_dynamic_templates.empty?

      # Use first type name or _doc
      { (types.first || :_doc) => result }
    end

    def deep_merge_mappings(base, overlay)
      return overlay if base.nil?
      return base if overlay.nil?

      base.merge(overlay) do |key, old_val, new_val|
        if old_val.is_a?(Hash) && new_val.is_a?(Hash)
          deep_merge_mappings(old_val, new_val)
        elsif old_val.is_a?(Array) && new_val.is_a?(Array)
          old_val + new_val
        else
          new_val
        end
      end
    end
  end
end
