require 'zip/filesystem'

module Problems
  class BaseExporter
    def self.export(problem, path, options = {})
      exporter = self.new(problem)
      # redirect to export zip etc if zip path etc
      extension = Array(path.match(/\.[[:alnum:]]+?\z/))[0]
      context = case extension
      when '.zip'; :enter_zip
      else; :enter_fs
      end
      exporter.send(context, path, options) do |path, options|
        exporter.around_export(path, options) do |path, options|
          exporter.export(path, options)
        end
      end
    end

    attr_accessor :problem, :dir, :file

    def initialize(problem)
      self.problem = problem
      self.dir = Dir
      self.file = File
      self.tempfiles = []
    end

    def around_export(path, options)
      yield(path, options)
    end

    def enter_fs
      yield
    end

    def enter_zip(path, options = {})
      zippath = path
      Zip::File.open(zippath, Zip::File::CREATE) do |zfs|
        chfs(zfs.dir, zfs.file) do
          yield '/', options
        end
      end
      tempfiles.each { |f| f.unlink }
      zippath
    end

    def chfs(dir, file)
      self.dir, self.file, cache = dir, file, [self.dir, self.file]
      if block_given?
        result = yield
        self.dir, self.file = cache
      end
      result
    end

    # core function
    def export(path, options)
      raise "Not implemented"
    end

    private
    attr_accessor :tempfiles
  end
end
