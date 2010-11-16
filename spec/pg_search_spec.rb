require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "an ActiveRecord model which includes PgSearch" do

  with_model :model_with_pg_search do
    table do |t|
      t.string 'title'
      t.text 'content'
      t.integer 'importance'
    end

    model do
      include PgSearch
    end
  end

  describe ".pg_search_scope" do
    it "builds a scope" do
      model_with_pg_search.class_eval do
        pg_search_scope "matching_query", :against => []
      end

      lambda {
        model_with_pg_search.scoped({}).matching_query("foo").scoped({})
      }.should_not raise_error
    end

    context "when passed a lambda" do
      it "builds a dynamic scope" do
        model_with_pg_search.class_eval do
          pg_search_scope :search_title_or_content, lambda { |query, pick_content|
            {
              :query => query.gsub("-remove-", ""),
              :against => pick_content ? :content : :title
            }
          }
        end

        included = model_with_pg_search.create!(:title => 'foo', :content => 'bar')
        excluded = model_with_pg_search.create!(:title => 'bar', :content => 'foo')

        model_with_pg_search.search_title_or_content('fo-remove-o', false).should == [included]
        model_with_pg_search.search_title_or_content('b-remove-ar', true).should == [included]
      end
    end
  end

  describe "a search scope" do
    context "against a single column" do
      before do
        model_with_pg_search.class_eval do
          pg_search_scope :search_content, :against => :content
        end
      end

      it "returns rows where the column contains the term in the query" do
        included = model_with_pg_search.create!(:content => 'foo')
        excluded = model_with_pg_search.create!(:content => 'bar')

        results = model_with_pg_search.search_content('foo')
        results.should include(included)
        results.should_not include(excluded)
      end

      it "returns rows where the column contains all the terms in the query in any order" do
        included = [model_with_pg_search.create!(:content => 'foo bar'),
                    model_with_pg_search.create!(:content => 'bar foo')]
        excluded = model_with_pg_search.create!(:content => 'foo')

        results = model_with_pg_search.search_content('foo bar')
        results.should =~ included
        results.should_not include(excluded)
      end

      it "returns rows that match the query but not its case" do
        # \303\241 is a with acute accent
        # \303\251 is e with acute accent

        included = [model_with_pg_search.create!(:content => "foo"),
                    model_with_pg_search.create!(:content => "FOO")]

        results = model_with_pg_search.search_content("Foo")
        results.should =~ included
      end

      it "returns rows that match the query only if their diacritics match" do
        # \303\241 is a with acute accent
        # \303\251 is e with acute accent

        included = model_with_pg_search.create!(:content => "abcd\303\251f")
        excluded = model_with_pg_search.create!(:content => "\303\241bcdef")

        results = model_with_pg_search.search_content("abcd\303\251f")
        results.should == [included]
        results.should_not include(excluded)
      end

      it "returns rows that match the query but not rows that are prefixed by the query" do
        included = model_with_pg_search.create!(:content => 'pre')
        excluded = model_with_pg_search.create!(:content => 'prefix')

        results = model_with_pg_search.search_content("pre")
        results.should == [included]
        results.should_not include(excluded)
      end

      it "returns rows that match the query when stemmed by the default dictionary (english)" do
        included = [model_with_pg_search.create!(:content => "jump"),
                    model_with_pg_search.create!(:content => "jumped"),
                    model_with_pg_search.create!(:content => "jumping")]

        results = model_with_pg_search.search_content("jump")
        results.should =~ included
      end

      it "returns rows that match sorted by rank" do
        loser = model_with_pg_search.create!(:content => 'foo')
        winner = model_with_pg_search.create!(:content => 'foo foo')

        results = model_with_pg_search.search_content("foo")
        results[0].rank.should > results[1].rank
        results.should == [winner, loser]
      end

      it "returns results that match sorted by primary key for records that rank the same" do
        sorted_results = [model_with_pg_search.create!(:content => 'foo'),
                          model_with_pg_search.create!(:content => 'foo')].sort_by(&:id)

        results = model_with_pg_search.search_content("foo")
        results.should == sorted_results
      end

      it "returns results that match a query with multiple space-separated search terms" do
        included = [
          model_with_pg_search.create!(:content => 'foo bar'),
          model_with_pg_search.create!(:content => 'bar foo'),
          model_with_pg_search.create!(:content => 'bar foo baz'),
        ]
        excluded = [
          model_with_pg_search.create!(:content => 'foo'),
          model_with_pg_search.create!(:content => 'foo baz')
        ]

        results = model_with_pg_search.search_content('foo bar')
        results.should =~ included
        results.should_not include(excluded)
      end

      it "returns rows that match a query with characters that are invalid in a tsquery expression" do
        included = model_with_pg_search.create!(:content => 'foo')

        results = model_with_pg_search.search_content(" foo &,' ")
        results.should == [included]
      end
    end

    context "against multiple columns" do
      before do
        model_with_pg_search.class_eval do
          pg_search_scope :search_title_and_content, :against => [:title, :content]
        end
      end

      it "returns rows whose columns contain all of the terms in the query across columns" do
        included = [
          model_with_pg_search.create!(:title => 'foo', :content => 'bar'),
          model_with_pg_search.create!(:title => 'bar', :content => 'foo')
        ]
        excluded = [
          model_with_pg_search.create!(:title => 'foo', :content => 'foo'),
          model_with_pg_search.create!(:title => 'bar', :content => 'bar')
        ]

        results = model_with_pg_search.search_title_and_content('foo bar')

        results.should =~ included
        excluded.each do |result|
          results.should_not include(result)
        end
      end

      it "returns rows where at one column contains all of the terms in the query and another does not" do
        included = model_with_pg_search.create!(:title => 'foo', :content => 'bar')
        results  = model_with_pg_search.search_title_and_content('foo')
        results.should == [included]
      end

      # Searching with a NULL column will prevent any matches unless we coalesce it.
      it "returns rows where at one column contains all of the terms in the query and another is NULL" do
        included = model_with_pg_search.create!(:title => 'foo', :content => nil)
        results  = model_with_pg_search.search_title_and_content('foo')
        results.should == [included]
      end
    end

    context "using trigram" do
      before do
        model_with_pg_search.class_eval do
          pg_search_scope :with_trigrams, :against => [:title, :content], :using => :trigram
        end
      end

      it "returns rows where one searchable column and the query share enough trigrams" do
        included = model_with_pg_search.create!(:title => 'abcdefghijkl', :content => nil)
        results = model_with_pg_search.with_trigrams('cdefhijkl')
        results.should == [included]
      end

      it "returns rows where multiple searchable columns and the query share enough trigrams" do
        included = model_with_pg_search.create!(:title => 'abcdef', :content => 'ghijkl')
        results = model_with_pg_search.with_trigrams('cdefhijkl')
        results.should == [included]
      end
    end

    context "using multiple features" do
      before do
        model_with_pg_search.class_eval do
          pg_search_scope :with_tsearch, :against => :title, :using => :tsearch
          pg_search_scope :with_trigram, :against => :title, :using => :trigram
          pg_search_scope :with_tsearch_and_trigram, :against => :title, :using => [:tsearch, :trigram]
        end
      end

      it "returns rows that match using any of the features" do
        record = model_with_pg_search.create!(:title => "tiling is grouty")

        # matches trigram only
        trigram_query = "ling is grouty"
        model_with_pg_search.with_trigram(trigram_query).should include(record)
        model_with_pg_search.with_tsearch(trigram_query).should_not include(record)
        model_with_pg_search.with_tsearch_and_trigram(trigram_query).should == [record]

        # matches tsearch only
        tsearch_query = "tile"
        model_with_pg_search.with_tsearch(tsearch_query).should include(record)
        model_with_pg_search.with_trigram(tsearch_query).should_not include(record)
        model_with_pg_search.with_tsearch_and_trigram(tsearch_query).should == [record]
      end
    end

    context "normalizing diacritics" do
      before do
        model_with_pg_search.class_eval do
          pg_search_scope :search_title_without_diacritics, :against => :title, :normalizing => :diacritics
        end
      end

      it "returns rows that match the query but not its diacritics" do
        # \303\241 is a with acute accent
        # \303\251 is e with acute accent

        included = model_with_pg_search.create!(:title => "\303\241bcdef")

        results = model_with_pg_search.search_title_without_diacritics("abcd\303\251f")
        results.should == [included]
      end
    end

    context "normalizing prefixes" do
      before do
        model_with_pg_search.class_eval do
          pg_search_scope :search_title_with_prefixes, :against => :title, :normalizing => :prefixes
        end
      end

      it "returns rows that match the query and that are prefixed by the query" do
        included = model_with_pg_search.create!(:title => 'prefix')
        excluded = model_with_pg_search.create!(:title => 'postfix')

        results = model_with_pg_search.search_title_with_prefixes("pre")
        results.should == [included]
        results.should_not include(excluded)
      end
    end

    context "with the simple dictionary" do
      before do
        model_with_pg_search.class_eval do
          pg_search_scope :search_title, :against => :title
          pg_search_scope :search_title_with_simple, :against => :title, :with_dictionary => :simple
        end
      end

      it "returns rows that match the query exactly but not that match the query when stemmed by the default dictionary" do
        included = model_with_pg_search.create!(:title => "jumped")
        excluded = [model_with_pg_search.create!(:title => "jump"),
                    model_with_pg_search.create!(:title => "jumping")]

        default_results = model_with_pg_search.search_title("jumped")
        default_results.should =~ [included] + excluded

        simple_results = model_with_pg_search.search_title_with_simple("jumped")
        simple_results.should == [included]
        excluded.each do |result|
          simple_results.should_not include(result)
        end
      end
    end

    context "against columns ranked with arrays" do
      before do
        model_with_pg_search.class_eval do
           pg_search_scope :search_weighted_by_array_of_arrays, :against => [[:content, 'B'], [:title, 'A']]
         end
      end

      it "returns results sorted by weighted rank" do
        loser = model_with_pg_search.create!(:title => 'bar', :content => 'foo')
        winner = model_with_pg_search.create!(:title => 'foo', :content => 'bar')

        results = model_with_pg_search.search_weighted_by_array_of_arrays('foo')
        results[0].rank.should > results[1].rank
        results.should == [winner, loser]
      end
    end

    context "against columns ranked with a hash" do
      before do
        model_with_pg_search.class_eval do
          pg_search_scope :search_weighted_by_hash, :against => {:content => 'B', :title => 'A'}
        end
      end

      it "returns results sorted by weighted rank" do
        loser = model_with_pg_search.create!(:title => 'bar', :content => 'foo')
        winner = model_with_pg_search.create!(:title => 'foo', :content => 'bar')

        results = model_with_pg_search.search_weighted_by_hash('foo')
        results[0].rank.should > results[1].rank
        results.should == [winner, loser]
      end
    end

    context "against columns of which only some are ranked" do
      before do
        model_with_pg_search.class_eval do
          pg_search_scope :search_weighted, :against => [:content, [:title, 'A']]
        end
      end

      it "returns results sorted by weighted rank using an implied low rank for unranked columns" do
        loser = model_with_pg_search.create!(:title => 'bar', :content => 'foo')
        winner = model_with_pg_search.create!(:title => 'foo', :content => 'bar')

        results = model_with_pg_search.search_weighted('foo')
        results[0].rank.should > results[1].rank
        results.should == [winner, loser]
      end
    end

    context "when passed a :ranked_by expression" do
      before do
        model_with_pg_search.class_eval do
          pg_search_scope :search_content_with_default_rank,
                          :against => :content
          pg_search_scope :search_content_with_importance_as_rank,
                          :against => :content,
                          :ranked_by => "importance"
          pg_search_scope :search_content_with_importance_as_rank_multiplier,
                          :against => :content,
                          :ranked_by => ":tsearch_rank * importance"
        end
      end

      it "should return records with a rank attribute equal to the :ranked_by expression" do
        model_with_pg_search.create!(:content => 'foo', :importance => 10)
        results = model_with_pg_search.search_content_with_importance_as_rank("foo")
        results.first.rank.should == 10
      end

      it "should substitute :tsearch_rank with the tsearch rank expression in the :ranked_by expression" do
        model_with_pg_search.create!(:content => 'foo', :importance => 10)

        tsearch_rank = model_with_pg_search.search_content_with_default_rank("foo").first.rank
        multiplied_rank = model_with_pg_search.search_content_with_importance_as_rank_multiplier("foo").first.rank

        multiplied_rank.should be_within(0.001).of(tsearch_rank * 10)
      end

      it "should return results in descending order of the value of the rank expression" do
        records = [
          model_with_pg_search.create!(:content => 'foo', :importance => 1),
          model_with_pg_search.create!(:content => 'foo', :importance => 3),
          model_with_pg_search.create!(:content => 'foo', :importance => 2)
        ]

        results = model_with_pg_search.search_content_with_importance_as_rank("foo")
        results.should == records.sort_by(&:importance).reverse
      end
    end
  end
end
