#!/usr/bin/ruby

require_relative 'githubapi'
require_relative 'githubclient'

class GithubPRWorker
  def initialize(base_parameters = {}, config = {})
    @base_parameters = base_parameters
    @config = config
  end

  # metadata for octokit
  def metadata(org, repo, context)
    {
      org_repo: org + "/" + repo,
      organization: org,
      repository: repo,
      context: context,
      config_base_path: File.dirname(@base_parameters[:config]),
      dryrun: @base_parameters[:dryrun] ? true : false,
    }
  end

  def process_list
    @config["pr_processing"] || []
  end

  def status_filter_config(config)
    # the config for the Status filter might be overridden via command line parameters
    if (@base_parameters.has_key?(:mode) && @base_parameters[:mode].to_s.size > 0) then
      config["status"] = @base_parameters[:mode]
    end
    config
  end

  def debug?
    @base_parameters.has_key?(:debugfilterchain) && \
      @base_parameters[:debugfilterchain] == true
  end

  def debug_message(msg)
    return unless msg
    puts msg
  end

  def debug_filter(filter)
    return unless filter
    puts filter.inspect
  end

  def debug_handler(handler)
    debug_filter(handler)
  end

  def debug_pulls(pulls)
    return unless pulls
    print_pulls(pulls)
  end

  def debug_print(content)
    return unless debug?
    puts content[:pre] * 25 if content[:pre]
    debug_message(content[:message])
    debug_filter(content[:filter])
    debug_handler(content[:handler])
    debug_pulls(content[:pulls])
  end


  def run_actions(pulls, actions)
    return unless actions.is_a?(Array)
    actions.each do |a|
      a.run(pulls)
    end
  end

  def repos(item)
    if (item["config"].has_key?("repositories") && item["config"]["repositories"].size > 0) then
      item["config"]["repositories"]
    elsif (item["config"].has_key?("repository_filter") && item["config"]["repository_filter"].size > 0) then
      c = GithubAPI.new.client
      c.repositories(item["config"]["organization"]).collect do |r|
        r.name if item["config"]["repository_filter"].find do |rf|
          r.name =~ rf
        end
      end.compact
    end
  end

  def run_filterchain(filterchain, mode, white)
    filterchain.each do |h|
      white, black = h[:filter].filter(white)
      debug_print(:message => "Filtering with:",
                  :filter  => h[:filter],
                  :pre     => "F " )
      if (mode == :process) then
         run_actions(black, h[:blacklist_handler])
         run_actions(white, h[:whitelist_handler])
      end
      debug_print(:message => "Blacklist handler:",
                  :handler => h[:blacklist_handler],
                  :pulls   => black,
                  :pre     => "- " )
      debug_print(:message => "Whitelist handler:",
                  :handler => h[:whitelist_handler],
                  :pulls   => white,
                  :pre     => "+ " )
      # if pass_through defines some other than "white"
      case h[:filter].pass_through
        when "black"
          white, black = black, []
        when "all"
          white, black = white + black, []
      end
    end
    return white
  end

  def filter_pulls(mode = :get, state = :open)
    process_list.collect do |item|
      repos(item).collect do |repo|
        debug_print(:message => "Processing: #{item['config']['organization']}/#{repo}",
                    :pre     => "==" )
        meta = metadata(item["config"]["organization"], repo, item["config"]["context"])
        if @base_parameters.has_key?(:only_repo) then
          next nil unless @base_parameters[:only_repo] == meta[:org_repo]
        end
        filterchain=[]
        if @base_parameters.has_key?(:only_pr)
          this = GithubPR::ThisPullRequestFilter.new(meta, @base_parameters[:only_pr])
          filterchain.push({filter: this})
        end
        Array(item["filter"]).each do |pull_filter|
          handler = {}
          fname = "GithubPR::" + pull_filter["type"] + "Filter"
          fname = "GithubPR::Filter" if
            pull_filter.has_key?("skippable") &&
            pull_filter["skippable"] &&
            @base_parameters.has_key?(:skip) &&
            @base_parameters[:skip]
          filter_config = pull_filter["config"]
          filter_config = status_filter_config(filter_config) if pull_filter["type"] == "Status"
          filter_config["pass_through"] = pull_filter["pass_through"] if pull_filter.has_key?("pass_through") && pull_filter["pass_through"]
          handler[:filter] = Object.const_get(fname).new(meta, filter_config)

          ["black", "white"].each do |list|
            hname = "#{list}list_handler"
            next unless pull_filter[hname]

            handler[hname.to_sym] = pull_filter[hname].collect do |one_action|
              action_class = "GithubPR::" + one_action["type"] + "Action"
              Object.const_get(action_class).new(meta, one_action["parameters"])
            end
          end
          filterchain.push(handler)
        end

        white = GithubClient.new(meta).all_pull_requests(state)
        debug_print(:message => "=> Full and unfiltered PR list:",
                    :pulls   => white,
                    :pre     => "PR " )
        run_filterchain(filterchain, mode, white)
      end.reject{ |x| x.nil? }
    end.flatten(2)
  end

  def print_pulls(pull)
    if pull.is_a?(Array)
      pull.each do |p|
        print_pulls(p)
      end
    else
      puts "#{pull.number}:#{pull.head.sha}:#{pull.base.ref}" if pull
    end
  end

  def trigger_pulls
    filter_pulls(:process, :open)
  end

  def get_pulls
    filter_pulls(:get, :open)
  end

  def list_pulls
    print_pulls(get_pulls)
  end
end
