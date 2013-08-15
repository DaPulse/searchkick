require "rake"

namespace :searchkick do

  desc "reindex model"
  task :reindex => :environment do
    if ENV["CLASS"]
      klass = ENV["CLASS"].constantize rescue nil
      if klass
        klass.reindex
      else
        abort "Could not find class: #{ENV["CLASS"]}"
      end
    else
      abort "USAGE: rake searchkick:reindex CLASS=Product"
    end
  end

  if defined?(Rails)

    namespace :reindex do
      desc "reindex all models"
      task :all => :environment do
        Rails.application.eager_load!
        (Searchkick::Reindex.instance_variable_get(:@descendents) || []).each do |model|
          model.reindex
        end
      end
    end

  end

end
