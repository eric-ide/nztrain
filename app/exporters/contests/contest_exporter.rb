require 'csv'

module Contests
  class ContestExporter < BaseExporter
    include RenderAnywhere

    def export(path, options = {})
      subpath = File.expand_path('submissions', path)
      dir.mkdir(subpath)
      submissions = []
      scoreboard = contest.scoreboard
      problems = contest.problem_set.problems
      previous_record = scoreboard.first
      rank = 1

      unofficial_scoreboard = CSV.generate do |csv|
        csv << ["Rank", "User ID", "Real Name", "Username", "School", "Year"] + problems.map{ |p| p.name } + ["Total Score", "Time"]
        scoreboard.each_with_index do |record, index|
          unofficial = record.user.nil? || record.user.school.nil? || record.school_year.nil? || record.user.country_code != "NZ"
          rank = index + 1 unless previous_record.score == record.score and previous_record.time_taken == record.time_taken
          row = [rank, record.user&.id, record.user&.name, record.user&.username, unofficial ? nil : record.user&.school&.name, record.school_year]
          problems.each do |prob|
            submissions += contest.get_submissions(record.user.id, prob.id) unless record.user.nil?
            row << record["score_#{prob.id}"]
          end
          row += [record.score, format("%d:%02d:%02d",record.time_taken.to_i/3600,record.time_taken.to_i/60%60,record.time_taken.to_i%60)]
          csv << row
          previous_record = record
        end
      end

      official_scoreboard = CSV.generate do |csv|
        csv << ["Rank", "User ID", "Real Name", "Username", "School", "Year"] + problems.map{ |p| p.name } + ["Total Score", "Time"]
        skipped = 0
        scoreboard.each_with_index do |record, index|
          if record.user.nil? || record.user.school.nil? || record.school_year.nil? || record.user.country_code != "NZ"
            skipped += 1
            next
          end
          rank = index + 1 - skipped unless previous_record.score == record.score and previous_record.time_taken == record.time_taken
          row = [rank, record.user&.id, record.user&.name, record.user&.username, record.user&.school&.name, record.school_year]
          problems.each do |prob|
            row << record["score_#{prob.id}"]
          end
          row += [record.score, format("%d:%02d:%02d",record.time_taken.to_i/3600,record.time_taken.to_i/60%60,record.time_taken.to_i%60)]
          csv << row
          previous_record = record
        end
      end

      submissions.each do |sub|
        file.open(File.expand_path("#{sub.id}.txt", subpath), 'w') do |f|
          f.write sub.source
          tempfiles << f
        end
      end

      file.open(File.expand_path('unofficial_scoreboard.csv', path), 'wb') do |f|
        f.write unofficial_scoreboard
        tempfiles << f
      end

      file.open(File.expand_path('official_scoreboard.csv', path), 'wb') do |f|
        f.write official_scoreboard
        tempfiles << f
      end

      file.open(File.expand_path('contest.json', path), 'w') do |f|
        f.write contest.to_json(include: {
          problem_set: {include: :problems},
          contestants: {include: :school},
          contest_relations: {},
          scoreboard: {},
        })
        tempfiles << f
      end

      file.open(File.expand_path('submissions.json', path), 'w') do |f|
        f.write submissions.to_json(
          include: {language: {only: :name}},
          except: [:judge_log, :source],
        )
        tempfiles << f
      end

      path
    end

    def around_export(path, options)
      super
    end

  end
end

