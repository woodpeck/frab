class StaticProgramExport

  EXPORT_PATH = Rails.root.join("tmp", "static_export")

  def initialize(conference, locale = nil)
    @conference = conference
    @locale = locale

    @asset_paths = []
    @base_directory = EXPORT_PATH.join(@conference.acronym)
    @base_url = URI.parse(@conference.program_export_base_url).path
    @base_url += '/' unless @base_url.end_with?('/')
    @original_schedule_public = @conference.schedule_public

    @session = ActionDispatch::Integration::Session.new(Frab::Application)
    @session.host = Settings.host
    @session.https! if Settings['protocol'] == "https"
  end

  def self.create_tarball(conference)
    out_file = EXPORT_PATH.join(conference.acronym + ".tar.gz")
    if File.exist? out_file
      File.unlink out_file
    end
    system( 'tar', *['-cpz', '-f', out_file.to_s, '-C', EXPORT_PATH.to_s, conference.acronym].flatten )
    out_file
  end

  def run_export
    ActiveRecord::Base.transaction do
      unlock_schedule unless @original_schedule_public

      setup_directories
      download_pages
      copy_stripped_assets
      create_index_page

      lock_schedule unless @original_schedule_public
    end
  end

  private

  def setup_directories
    FileUtils.rm_r(@base_directory, secure: true) if File.exist? @base_directory
    FileUtils.mkdir_p(@base_directory)
  end

  def download_pages
    paths = get_query_paths
    path_prefix = "/#{@conference.acronym}/public"
    unless @locale.nil?
      path_prefix = "/#{@locale}" + path_prefix
    end
    paths.each { |p| save_response("#{path_prefix}/#{p[:source]}", p[:target]) }
  end

  def copy_stripped_assets
    @asset_paths.uniq.each do |asset_path|
      original_path = File.join(Rails.root, "public", URI.unescape(asset_path))
      if File.exist? original_path
        new_path = File.join(@base_directory, URI.unescape(asset_path))
        FileUtils.mkdir_p(File.dirname(new_path))
        FileUtils.cp(original_path, new_path)
      else
        STDERR.puts '?? We might be missing "%s"' % original_path
      end
    end
  end

  def create_index_page
    schedule_file = File.join(@base_directory, 'schedule.html')
    if File.exist? schedule_file
      FileUtils.cp(schedule_file, File.join(@base_directory, 'index.html'))
    end
  end

  def get_query_paths
    paths = [
        {source: "schedule", target: "schedule.html"},
        {source: "events", target: "events.html"},
        {source: "speakers", target: "speakers.html"},
        {source: "speakers.json", target: "speakers.json"},
        {source: "schedule/style.css", target: "style.css"},
        {source: "schedule.ics", target: "schedule.ics"},
        {source: "schedule.xcal", target: "schedule.xcal"},
        {source: "schedule.json", target: "schedule.json"},
        {source: "schedule.xml", target: "schedule.xml"},
    ]

    day_index = 0
    @conference.days.each do |day|
      paths << {source: "schedule/#{day_index}", target: "schedule/#{day_index}.html"}
      paths << {source: "schedule/#{day_index}.pdf", target: "schedule/#{day_index}.pdf"}
      day_index += 1
    end

    @conference.events.public.confirmed.scheduled.each do |event|
      paths << {source: "events/#{event.id}", target: "events/#{event.id}.html"}
      paths << {source: "events/#{event.id}", target: "events/#{event.id}.ics"}
    end
    Person.publicly_speaking_at(@conference).confirmed(@conference).each do |speaker|
      paths << {source: "speakers/#{speaker.id}", target: "speakers/#{speaker.id}.html"}
    end
    paths
  end

  def save_response(source, filename)
    status_code = @session.get(source)
    unless status_code == 200
      STDERR.puts '!! Failed to fetch "%s" as "%s" with error code %d' % [ source, filename, status_code ]
      return 
    end

    file_path = File.join(@base_directory, URI.decode(filename))
    FileUtils.mkdir_p(File.dirname(file_path))

    if filename =~ /\.html$/
      document = modify_response_html(filename)
      File.open(file_path, "w") do |f| 
        # FIXME corrupts events and speakers?
        #document.write_html_to(f, encoding: "UTF-8")
        f.puts(document.to_html)
      end
    elsif filename =~ /\.pdf$/
      File.open(file_path, "wb") do |f| 
        f.write(@session.response.body)
      end
    else
      # CSS,...
      File.open(file_path, "w:utf-8") do |f| 
        f.write(@session.response.body.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?"))
      end
    end
  end

  def modify_response_html(filename)
    document = Nokogiri::HTML(@session.response.body, nil, "UTF-8")
    
    # <link>
    document.css("link").each do |link|
      href_attr = link.attributes["href"]
      if href_attr.value.index("/#{@conference.acronym}/public/schedule/style.css")
        link.attributes["href"].value = @base_url + "style.css"
      else
        strip_asset_path(link, "href") if href_attr
      end
    end

    # <script>
    document.css("script").each do |script|
      strip_asset_path(script, "src") if script.attributes["src"]
    end
    
    # <img>
    document.css("img").each do |image|
      strip_asset_path(image, "src")
    end
    
    # <a>
    document.css("a").each do |link|
      href = link.attributes["href"] 
      if href and href.value.start_with?("/")
        if href.value =~ /\?\d+$/
          strip_asset_path(link, "href")
        else
          path = @base_url + strip_path(href.value)
          path += ".html" unless path =~ /\.\w+$/
          href.value = path
        end
      end
    end
    document
  end

  def strip_asset_path(element, attribute)
    path = strip_path(element.attributes[attribute].value)
    @asset_paths << path
    element.attributes[attribute].value = @base_url + path
  end

  def strip_path(path)
    path.gsub(/^\//, "").gsub(/^(?:en|de)?\/?#{@conference.acronym}\/public\//, "").gsub(/\?(?:body=)?\d+$/, "")
  end

  def unlock_schedule
    Conference.paper_trail_off
    @conference.schedule_public = true
    @conference.save!
  end

  def lock_schedule
    @conference.schedule_public = @original_schedule_public
    @conference.save!
    Conference.paper_trail_on
  end

end
