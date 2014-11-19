#!/usr/bin/env ruby

require 'github_api'
require 'json'
require 'colorize'
require_relative 'github_changelog_generator/parser'
require_relative 'github_changelog_generator/version'

module GitHubChangelogGenerator
  class ChangelogGenerator

    attr_accessor :options, :all_tags, :github

    def initialize

      @options = Parser.parse_options

      github_token

      if @github_token.nil?
        @github = Github.new
      else
        @github = Github.new oauth_token: @github_token
      end

      @all_tags = self.get_all_tags
      @pull_requests = self.get_all_closed_pull_requests
      if @options[:issues]
        @issues = self.get_all_issues
      else
        @issues = []
      end

      @tag_times_hash = {}
    end

    def print_json(json)
      puts JSON.pretty_generate(json)
    end

    def exec_command(cmd)
      exec_cmd = "cd #{$project_path} && #{cmd}"
      %x[#{exec_cmd}]
    end


    def get_all_closed_pull_requests

      if @options[:verbose]
        puts 'Fetching pull requests..'
      end

      response = @github.pull_requests.list @options[:user], @options[:project], :state => 'closed'

      pull_requests = []
      response.each_page do |page|
        pull_requests.concat(page)
      end

      if @options[:verbose]
        puts "Received all closed pull requests: #{pull_requests.count}"
      end

      filtered_pull_requests = pull_requests.select { |pull_request|
        #We need issue to fetch labels
        issue = @github.issues.get @options[:user], @options[:project], pull_request.number
        #compare is there any labels from @options[:labels] array
        select_no_label = !issue.labels.map { |label| label.name }.any?
        select_by_label = (issue.labels.map { |label| label.name } & @options[:labels]).any?
        select_by_label | select_no_label
      }

      if @options[:verbose]
        puts "Filtered pull requests with specified labels and w/o labels: #{filtered_pull_requests.count}"
      end

      pull_requests
    end

    def compund_changelog
      if @options[:verbose]
        puts 'Generating changelog:'
      end

      log = "# Changelog\n\n"

      if @options[:last]
        log += self.generate_log_between_tags(self.all_tags[0], self.all_tags[1])
      elsif @options[:tag1] && @options[:tag2]

        tag1 = @options[:tag1]
        tag2 = @options[:tag2]
        tags_strings = []
        self.all_tags.each { |x| tags_strings.push(x['name']) }

        if tags_strings.include?(tag1)
          if tags_strings.include?(tag2)
            hash = Hash[tags_strings.map.with_index.to_a]
            index1 = hash[tag1]
            index2 = hash[tag2]
            log += self.generate_log_between_tags(self.all_tags[index1], self.all_tags[index2])
          else
            puts "Can't find tag #{tag2} -> exit"
            exit
          end
        else
          puts "Can't find tag #{tag1} -> exit"
          exit
        end
      else
        log += self.generate_log_for_all_tags
      end

      log += "\n\n\\* *This changelog was generated by [github_changelog_generator](https://github.com/skywinder/Github-Changelog-Generator)*"

      output_filename = "#{@options[:output]}"
      File.open(output_filename, 'w') { |file| file.write(log) }

      puts "Done! Generated log placed in #{output_filename}"

    end

    def generate_log_for_all_tags
      log = ''
      @all_tags.each { |tag| self.get_time_of_tag(tag) }


      if @options[:verbose]
        puts "Sorting tags.."
      end

      @all_tags.sort_by! { |x| self.get_time_of_tag(x) }.reverse!

      if @options[:verbose]
        puts "Generating log.."
      end

      for index in 1 ... self.all_tags.size
        log += self.generate_log_between_tags(self.all_tags[index], self.all_tags[index-1])
      end

      log += self.generate_log_before_tag(self.all_tags.last)

      log
    end

    def is_megred(number)
      @github.pull_requests.merged? @options[:user], @options[:project], number
    end

    def get_all_tags

      if @options[:verbose]
        puts 'Fetching all tags..'
      end

      response = @github.repos.tags @options[:user], @options[:project]

      tags = []
      response.each_page do |page|
        tags.concat(page)
      end

      if @options[:verbose]
        puts "Found #{tags.count} tags"
      end

      tags
    end

    def github_token
      if @options[:token]
        return @github_token ||= @options[:token]
      end

      env_var = ENV.fetch 'CHANGELOG_GITHUB_TOKEN', nil

      unless env_var
        puts "Warning: No token provided (-t option) and variable $CHANGELOG_GITHUB_TOKEN was not found.".yellow
        puts "This script can make only 50 requests to GitHub API per hour without token!".yellow
      end

      @github_token ||= env_var

    end


    def generate_log_between_tags(older_tag, newer_tag)

      newer_tag_time = self.get_time_of_tag(newer_tag)
      newer_tag_name = newer_tag['name']

      if older_tag.nil?
        filtered_pull_requests = delete_by_time(@pull_requests ,:merged_at, newer_tag_time)
        issues = delete_by_time(@issues ,:closed_at, newer_tag_time)
      else
        older_tag_time = self.get_time_of_tag(older_tag)
        filtered_pull_requests = delete_by_time(@pull_requests ,:merged_at, newer_tag_time, older_tag_time)
        issues = delete_by_time(@issues ,:closed_at, newer_tag_time, older_tag_time)
      end

      self.create_log(filtered_pull_requests, issues, newer_tag_name, newer_tag_time)

    end

    def delete_by_time(array, hash_key, newer_tag_time, older_tag_time = nil)
      array_new = Array.new(array)
      array_new.delete_if { |req|
        if req[hash_key]
          t = Time.parse(req[hash_key]).utc

          if older_tag_time.nil?
            tag_is_older_of_older = false
          else
            tag_is_older_of_older = t > older_tag_time
          end

          tag_is_newer_than_new = t <= newer_tag_time

          tag_not_in_range = (tag_is_older_of_older) && (tag_is_newer_than_new)
          !tag_not_in_range
        else
          true
        end
      }
    end

    def generate_log_before_tag(tag)
      generate_log_between_tags(nil, tag)
    end

    def create_log(pull_requests, issues, tag_name, tag_time)

      # Generate tag name and link
      trimmed_tag = tag_name.tr('v', '')
      log = "## [#{trimmed_tag}] (https://github.com/#{@options[:user]}/#{@options[:project]}/tree/#{tag_name})\n"

      #Generate date string:
      time_string = tag_time.strftime @options[:format]
      log += "#### #{time_string}\n"

      if @options[:pulls]
        # Generate pull requests:
        if pull_requests
          if @options[:author]
            pull_requests.each { |dict|
              merge = "#{@options[:merge_prefix]}#{dict[:title]} [\\##{dict[:number]}](#{dict.html_url}) ([#{dict.user.login}](#{dict.user.html_url}))\n\n"
              log += "- #{merge}"
            }
          else
            pull_requests.each { |dict|
              merge = "#{@options[:merge_prefix]}#{dict[:title]} [\\##{dict[:number]}](#{dict.html_url})\n\n"
              log += "- #{merge}"
            }
          end

        end
      end

      if @options[:issues]
        # Generate issues:
        if issues
          issues.sort! { |x, y|
            if x.labels.any? && y.labels.any?
              x.labels[0].name <=> y.labels[0].name
            else
              if x.labels.any?
                1
              else
                if y.labels.any?
                  -1
                else
                  0
                end
              end
            end
          }.reverse!
        end
        issues.each { |dict|
          is_bug = false
          is_enhancement = false
          dict.labels.each { |label|
            if label.name == 'bug'
              is_bug = true
            end
            if label.name == 'enhancement'
              is_enhancement = true
            end
          }

          intro = 'Closed issue'
          if is_bug
            intro = 'Fixed bug'
          end

          if is_enhancement
            intro = 'Implemented enhancement'
          end

          merge = "*#{intro}:* #{dict[:title]} [\\##{dict[:number]}](#{dict.html_url})\n\n"
          log += "- #{merge}"
        }
      end
      log
    end

    def get_time_of_tag(prev_tag)

      if @tag_times_hash[prev_tag['name']]
        return @tag_times_hash[prev_tag['name']]
      end

      if @options[:verbose]
        puts "Getting time for tag #{prev_tag['name']}"
      end

      github_git_data_commits_get = @github.git_data.commits.get @options[:user], @options[:project], prev_tag['commit']['sha']
      time_string = github_git_data_commits_get['committer']['date']
      Time.parse(time_string)
      @tag_times_hash[prev_tag['name']] = Time.parse(time_string)
    end

    def get_all_issues

      if @options[:verbose]
        puts 'Fetching closed issues..'
      end

      response = @github.issues.list user: @options[:user], repo: @options[:project], state: 'closed', filter: 'all', labels: nil


      issues = []
      response.each_page do |page|
        issues.concat(page)
      end

      # remove pull request from issues:
      issues.select! { |x|
        x.pull_request == nil
      }

      if @options[:verbose]
        puts "Received closed issues: #{issues.count}"
      end

      filtered_issues = issues.select { |issue|
        #compare is there any labels from @options[:labels] array
        (issue.labels.map { |label| label.name } & @options[:labels]).any?
      }

      if @options[:add_issues_wo_labels]
        issues_wo_labels = issues.select {
          # add issues without any labels
            |issue| !issue.labels.map { |label| label.name }.any?
        }
        filtered_issues.concat(issues_wo_labels)
      end

      if @options[:verbose]
        puts "Filter issues with labels #{@options[:labels]}#{@options[:add_issues_wo_labels] ? ' and w/o labels' : ''}: #{filtered_issues.count} issues"
      end

      filtered_issues

    end

  end

  if __FILE__ == $0
    GitHubChangelogGenerator::ChangelogGenerator.new.compund_changelog
  end

end