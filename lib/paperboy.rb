require 'erb'
require 'open-uri'
require 'chartbeat'
require 'stats_combiner/filterer'
require 'hashie'
require 'nokogiri'

# **Paperboy** is a chartbeat-based library for creating 
# HTML files and automated daily newsletters from your most popular stories 
# over the course of a time period. It sniffs out META tags
# from URLs to build images and blurbs for the email.
# It builds on concepts from [stats_combiner.gem][sc] but relies on chartbeat's
# historical [snapshots][sn] endpoint, where stats_combiner uses real-time data.
#
# [sc]: http://github.com/tpm/stats_combiner
# [sn]: http://chartbeat.pbworks.com/snapshots
module Paperboy
  
  # `Paperboy::Collector` queries the chartbeat API's snapshots method
  # and consolidates viewers over the specified timespan. 
  # Then it pushes out barebones HTML to be gussied-up and sent.
  class Collector
        
    attr_accessor :outfile
    
    # Initialize a `Paperboy` instance. This script is relatively expensive, and
    # is ideally run on a cron, perhaps once a day. Unlike stats_combiner, Paperboy uses
    # historical data, so it really doesn't matter *when* you set this to run, as long as you're
    # grabbing relative timestamps.
    # 
    # API key and host come from your Chartbeat settings. 
    # Start and end times are UNIX timestamps. Paperboy will  collect hourly between them. 
    # It defaults to yesterday from midnight to midnight.
    # Filters is an instance of StatsCombiner::Filterer. To use it, first
    # instantiate a Filterer object with:
    #
    #    e = StatsCombiner::Filterer.new
    #
    # then add filter rules such as
    #
    #    e.add { 
    #      :prefix => 'tpmdc', 
    #      :title_regex => /\| TPMDC/, 
    #      :modify_title => true
    #    }
    #   
    # finally, pass `e.filters` to this method.
    #
    # `img_xpath` and `blurb_xpath` are xpath queries that will run on the URL extracted
    # from chartbeat (and any filters run on it) to populate your email with data that might
    # reside in META tags. Here some I've found useful. `*_xpath` takes the `content` attribute
    # of whatever HEAD tag is queried.
    #      
    #     :img_xpath => '//head/meta[@property="og:image"]',
    #     :blurb_xpath => '//head/meta[@name="description"]'
    #
    # Another option is `:interval`, which determines the interval of snapshots it takes before
    # `start_time` and `end_time`. The default is 3600 seconds, or one hour.
    #
    # Usage example:
    #     p = Paperboy::Collector.new {
    #      :api_key => 'chartbeat_api_key',  
    #      :host => 'yourdomain.com',
    #      :start_time => 1277784000
    #      :end_time => 1277870399,
    #      :interval => 3600,
    #      :filters => e.filters,
    #      :img_xpath => '//head/meta[@property="og:image"]',
    #      :blurb_xpath => '//head/meta[@name="description"]'
    #      }
    #
    # The static file generated by Paperboy will be called "yourdomain.com_paperboy_output.html."
    # Change this with `p.outfile`
    #
    def initialize(opts = {})
      @opts = {
        :apikey => nil,
        :host => nil,
        :start_time => Time.now.to_i - 18000, #four hour default window
        :end_time => Time.now.to_i - 3600,
        :interval => 3600,
        :filters => nil,
        :img_xpath => nil,
        :blurb_xpath => nil
      }.merge!(opts)
      
      if @opts[:apikey].nil? || @opts[:host].nil?
        raise Paperboy::Error, "No Chartbeat API Key or Host Specified!"
      end
      
      @c = Chartbeat.new :apikey => @opts[:apikey], :host => @opts[:host]
      @outfile = "#{@opts[:host]}_paperboy_output.html"
      
      @stories = []
      @uniq_stories = []
    end
    
    # **Run** runs the collector according to parameters set up in `new`.
    # By default, it will generate an HTML file in the current directory with a 
    # standard bare-bones structure. There is also an option to pass data through an 
    # ERB template. That is done like so:
    #
    #    p.run :via => 'erb', :template => '/path/to/tmpl.erb'
    #
    # ERB templates will expect to iterate over a `@stories` array, where each item is
    # a hash of story attributes. See Paperboy::View#erb below for more on templating.
    def run(opts = {})
      @run_opts = {
        :via => 'html',
        :template => nil
      }.merge!(opts)
      
      result = self.collect_stories      
      v = Paperboy::View.new(result,@outfile)
        
      if @run_opts[:via] == 'erb'
        if @run_opts[:template].nil?
          raise Paperboy::Error, "A template file must be specified with the erb option."
        end
        v.erb(@run_opts[:template])
      else
        v.html
      end
    end
    
    # Determine if there is an outfile for this instance. If so, get the filename.
    def outfile
      f = @outfile
      if File::exists?(f)
        puts f
      else
        raise Paperboy::Error, "No result file: #{f} Try calling `run` first in this directory"
      end
    end
    
    # Get the contents of the HTML file. I.e. the final product of the Paperboy run.
    def html
      File.open(@outfile).read
    end
    
    #### Internals
    
    protected
    
    # Find out how many times we'll have to query the Chartbeat API.
    # We'll only do it once per `@opts[:interval]` between start and end times.
    # By default, the interval is 3600 seconds.
    def get_collection_intervals  
      times = []
      i = @opts[:start_time]
      loop do        
        times << i
        i += @opts[:interval]
        break if i >= @opts[:end_time] || @opts[:end_time] - @opts[:start_time] < @opts[:interval]
      end
      times
    end
    
    # Query the chartbeat API via the chartbeat gem, and organize 
    # stories over the course of the day into a big array.
    def collect_stories
      times = self.get_collection_intervals
      
      times.each do |time|
        puts "Collecting for #{Time.at(time)}..."
        h = Hashie::Mash.new(@c.snapshots(:timestamp => time))
        
        titles = h.titles.to_a
        paths = h.active
        
        if not titles.nil? || paths.nil?
          paths_visitors = paths.collect {|q| [q.path,q.total]} 
          
          # Match titles to paths and add visitors.
          titles.each do |title|
            paths_visitors.each do |path_visitor|
              if path_visitor[0] == title[0]
                title << path_visitor[1]
              end
            end
          end
        else
          warn "Warning! No data collected for #{Time.at(time)}. Results may be skewed! Try setting older timestamps for best results."
        end
        
        @stories << titles
      end
      
      self.package_stories
    end

    # If filters are enabled, run each story through the Filterer, 
    # and modify URL and Title as necessary
    def filter_story(hed,path)
      filters = @opts[:filters]
      d = StatsCombiner::Filterer.apply_filters! @opts[:filters], :title => hed, :path => path
      if not d[:prefix].nil?
          d[:prefix] = d[:prefix] + '.'
      end       
      d[:url] = "http://#{d[:prefix]}#{@opts[:host]}#{path}"
      d
    end
    
    # Find out if we need to filter the stories, and send to `filter_story` if so.
    # Otherwise, weed out the dupes and get ready to package into something we can use.
    def prepackage_stories
      @stories.each do |hour|
        hour.each do |datum|
          path = datum[0].dup
          hed = datum[1].dup
          visitors = datum[2] || 0
          
          if @opts[:filters]
            d = self.filter_story(hed,path)
            hed = d[:title]
            path = d[:path]
            url = d[:url]
          else
            url = "http://#{@opts[:host]}#{path}"
          end
                    
          if not path.nil?
            if not @uniq_stories.collect {|q| q[1] }.include?(hed)
              @uniq_stories << [url,hed,visitors]
            else
              dupe_idx = @uniq_stories.collect{|q| q[1]}.index(hed)
              @uniq_stories[dupe_idx][2] += visitors
            end      
          end
        end
      end        
    end
    
    # First, send stories to be prepackaged. Then, sort them by visitors,
    # and start looking for blurbs and images out on the URLs themselves for the top ten.
    # At some point, it might be a good idea to make the number collected an option.
    # Finally, generate the HTML and save as a static file.
    def package_stories
      
      self.prepackage_stories
      
      uniq_stories = @uniq_stories.sort{|a,b| b[2] <=> a[2]}[0..9]
      
      story_pkgs = []
      
      uniq_stories.each do |story|
        story_pkg = []
        url = story[0]
        hed = story[1]
        visitors = story[2]
        
        begin
          d = Nokogiri::HTML(open(url))
          rescue OpenURI::HTTPError || Timeout::Error
            d = nil
        end
        
        # Only grab metadata and add this story to the stories array
        # if it's reachable. Otherwise, we'll assume it's a dead link and skip it.
        if not d.nil?
          description = d.xpath(@opts[:blurb_xpath]).attr('content').value rescue nil
          img = d.xpath(@opts[:img_xpath]).attr('content').value rescue nil
        
          story_pkg = {
            :url => url,
            :hed => hed,
            :visitors => visitors,
            :blurb => description || '',
            :img => img || ''
          }
          story_pkgs << story_pkg
        end      
      
      end
      
      story_pkgs
    end
  
  end

  #### Templating Paperboy

  # **Paperboy::View** is for templating Paperboy output.
  class View
    
    # Views are initialized from the `run` method of `PaperBoy::Collector`
    # but can also be invoked separately, if you have an array of stories.
    def initialize(story_pkgs,outfile)
      @stories = story_pkgs
      @outfile = outfile
    end
    
    # HTML is the default output method. It will return a bare-bones
    # page of story output including blurbs and images if available.
    def html

      html = ''
      
      @stories.each do |pkg|
      
        html << <<DOCUMENT
        <div class="story">
          <h2><a href="#{pkg[:url]}">#{pkg[:hed]}</a></h2>
DOCUMENT
        
        if not pkg[:img].empty?
          html << <<DOCUMENT
          <div class="img"><a href="#{pkg[:url]}"><img src="#{pkg[:img]}"></a></div>
DOCUMENT
        end
        
        if not pkg[:blurb].empty?
          html << <<DOCUMENT
          <div class="blurb">#{pkg[:blurb]}</div>
DOCUMENT
        end
        
        html << <<DOCUMENT
        </div>
DOCUMENT
      
      end
      
      self.write(html)
    end
    
    # Templatize your story output with embedded ruby.
    # This allows the greatest flexibility for presenting the data.
    # 
    # To use, access the `@stories` array, and it's component hashes.
    # Example:
    #
    #    <h1>My Popular Stories</h1>
    #         
    #      <% @stories.each do |story| %>
    #        <div class="story">
    #           <h2><a href="<%= story[:url] %>"><%= story[:hed] %></a></h2>
    #           <% if not story[:img].empty? %>
    #             <div class="img">
    #                <a href="<%= story[:url] %>">
    #                 <img src="<%= story[:img] %>">
    #                </a>
    #             </div>
    #           <% end %>
    #           <% if not story[:blurb].empty? %>
    #             <div class="blurb"><%= story[:blurb] %></div>
    #           <% end %>
    #        </div>
    #      <% end %>
    #
    def erb(template)
      t = File.open(template).read
      template = t.to_s      
      html = ERB.new(template).result(binding)
      
      self.write(html)
    end
    
    # Write out flat HTML to a file from either plain html or erb templating.
    def write(html)
      f = File.new(@outfile,"w+")      
      f.write(html)
      f.close
    end
  
  end

end

class Paperboy::Error < StandardError
end