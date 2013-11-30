class Judge
  ExeFileName = "program.exe"
  JudgeFileName = "judge.info"
  EvalFileName = "eval.sh"
  ExpectedFileName = "expect.out"
  CompileSandboxOptions ='-m262144 -w60 -e -i/dev/null'
  StackLimit = 1024 * 4 # 4 MB
  OutputBaseLimit = 1024 * 1024 * 2

  attr_accessor :program

  def initialize(program)
    self.program = program
  end

  def judge
    result = {}
    setup_judging do
      if program.language.interpreted
        File.open(File.expand_path(ExeFileName, tmpdir),"w") { |f| f.write(program.source) }
        run_command = program.language.compile_command(:source => ExeFileName)
      else
        result['compile'] = compile!(ExeFileName) # possible caching
        return result.merge!(grade_compile_error(result['compile'])) if result['compile']['stat'] != 0 #error

        run_command = "./#{ExeFileName}"
      end

      # test cases
      result['test_cases'] = {}
      problem.test_cases.each do |test_case|
        FileUtils.copy(File.expand_path(ExeFileName, tmpdir), box.expand_path(ExeFileName))
        result['test_cases'][test_case.id] = judge_test_case(test_case, run_command) unless result['test_cases'].has_key?(test_case.id)
      end

      # test sets
      denominator = problem.test_sets.map(&:points).inject(&:+).to_f
      result['test_sets'] = {}
      problem.test_sets.each do |test_set|
        result['test_sets'][test_set.id] = grade_test_set(test_set, result['test_cases'], denominator)
      end
      
      result.merge!(grade_program(result['test_sets'], denominator))
    end
    result
  end

  private
  attr_accessor :problem, :box, :tmpdir
  def setup_judging
    self.problem = program.problem
    Dir.mktmpdir do |tmpdir|
      self.tmpdir = tmpdir
      Isolate.box do |box|
        self.box = box
        yield
      end
    end
  end

  def compile! output
    result = program.language.compile(box, program.source, output, :mem => 262144, :wall_time => 60)
    FileUtils.copy(box.expand_path(output), File.expand_path(output, tmpdir)) if result['stat'] == 0
    return result
  ensure
    box.clean!
  end

  def judge_test_case(test_case, run_command)
    result = run_test_case(test_case, run_command)
    result['evaluator'] = evaluate_output(test_case, result['output'], result['output_size'], problem.evaluator)
    result['log'] = truncate_output(result['log']) # log only a small portion
    result['output'] = truncate_output(result['output'].slice(0,100)) # store only a small portion
    result
  end

  def run_test_case(test_case, run_command)
    resource_limits = { :mem => problem.memory_limit*1024, :time => problem.time_limit, :wall_time => problem.time_limit*3+5, :stack => StackLimit }
    stream_limit = OutputBaseLimit + test_case.output.bytesize*2
    run_opts = resource_limits.reverse_merge(:processes => false, :output_limit => stream_limit, :clean_utf8 => true)
    if program.input.nil?
      run_opts[:stdin_data] = test_case.input
    else
      box.fopen(program.input,"w") { |f| f.write(test_case.input) }
    end
    r={}
    (r['output'], r['output_size']), (r['log'], r['log_size']), (r['box'],), r['meta'], r['stat'] = box.capture5(run_command, run_opts)
    result = r
    result['stat'] = result['stat'].exitstatus
    result['time'] = [result['meta']['time'],problem.time_limit.to_f].min
    unless program.output.nil?
      if box.exist?(program.output)
        box.fopen(program.output) { |f| result['output'], result['output_size'] = box.read_pipe_limited(f, stream_limit) }
      else
        result['output'] = ""
        result['output_size'] = 0
      end
    end
    return result
  ensure
    box.clean!
  end

  def evaluate_output(test_case, output, output_size, evaluator)
    stream_limit = OutputBaseLimit + test_case.output.bytesize*2
    if output_size > stream_limit
      return {'evaluation' => 0, 'log' => "Output exceeded the streamsize limit of #{stream_limit}.", 'meta' => {'status' => 'OK'}}
    end
    expected = conditioned_output(test_case.output)
    actual = conditioned_output(output)
    if evaluator.nil?
      {'evaluation' => (actual == expected ? 1 : 0), 'meta' => {'status' => 'OK'}}
    else
      r = {}
      box.fopen(EvalFileName,"w") do |file|
        file.chmod(0700)
        file.write(problem.evaluator.source.gsub(/\r\n?/, "\n"))
      end
      resource_limits = { :mem => 262144, :time => problem.time_limit*3, :wall_time => problem.time_limit*3+30 }
      box.fopen("actual","w") { |f| f.write(actual) } # DEPRECATED
      box.fopen("input","w") { |f| f.write(test_case.input) } # DEPRECATED
      box.fopen("expected","w") { |f| f.write(expected) } # DEPRECATED
      deprecated_args = "input actual expected" # DEPRECATED
      eval_output = nil
      str_to_pipe(test_case.input, expected) do |input_stream, output_stream|
        run_opts = resource_limits.reverse_merge(:processes => true, 3 => input_stream, 4 => output_stream, :stdin_data => actual, :output_limit => OutputBaseLimit + test_case.output.bytesize*4, :clean_utf8 => true)
        (output,), (r['log'],r['log_size']), (r['box'],), result['meta'], status = box.capture5("./#{EvalFileName} #{deprecated_args}", run_opts )
        result = r
        result['log'] = truncate_output(r['log'])
        return result.merge('stat' => 2, 'box' => 'Output was not a valid UTF-8 encoding\n'+result['box']) if !output.force_encoding("UTF-8").valid_encoding?
        eval_output = output.strip.split(nil,2)
        result['stat'] = status.exitstatus
      end
      if eval_output.empty? # DEPRECATED
        if result['stat'] == 1 && result['meta']['status'] == 'RE' && result['meta']['exitcode'] == 1 # DEPRECATED
          result['evaluation'] = 0 
          result['meta']['status'] = 'OK'
        end
        result['evaluation'] = 1 if result['stat'] == 0 # DEPRECATED
      else
        result['evaluation'] = eval_output[0].to_f
        result['message'] = truncate_output(eval_output[1])
        result.delete('evaluation') if result['meta']['status'] != 'OK'
      end
      result['message'] = "No output.\n#{result['message']}" if output == ""
      result
    end
  ensure
    box.clean!
  end

  def grade_test_set test_set, evaluated_test_cases, denominator
    result = {'cases' => []}
    pending, error, sig = false, false, false
    evaluations = test_set.test_case_relations.map do |relation|
      id = relation.test_case_id
      result['cases'] << id
      next pending = true unless evaluated_test_cases.has_key?(id)
      test = evaluated_test_cases[id]
      break error = true if ((test['evaluator']||{})['meta']||{})['status'] != 'OK' || !test['evaluator'].has_key?('evaluation')
      sig = true if test['stat'] != 0
      test['evaluator'].fetch('evaluation', 0)
    end

    result['status'] = 0
    result['status'] = 1 if pending
    result['status'] = 2 if error
    if result['status'] == 0
      # test set = min case score
      result['evaluation'] = evaluations.push(1).min
      result['evaluation'] = 0 if sig # any signal/runtime error/timeout fails the test set
      result['score'] = (test_set.points * result['evaluation']).to_f*100/denominator
    end
    result
  end

  def grade_program(graded_sets, denominator)
    test_sets = problem.test_sets
    sets = graded_sets.values_at(*test_sets.map(&:id))
    result = {}
    result['status'] = [*sets.map{ |s| s['status'] }, (sets.compact.count<sets.count) ? 1 : 0].max
    if result['status'] == 0
      numerator = test_sets.map{ |s| (graded_sets[s.id]['evaluation'] * s.points)}.inject(&:+).to_f
      result['evaluation'] = numerator/denominator
      result['score'] = (result['evaluation']*100).floor
    end
    result
  end

  def grade_compile_error(compiled)
    case compiled['stat']
    when 0
      return { 'status' => 1 } # pending
    when 1
      return { 'status' => 0, 'evaluation' => 0.0, 'score' => 0 }
    else
      return { 'status' => 2 } # errored
    end
  end

  # Utility methods
  def str_to_pipe(*strings)
    pipes = strings.map do |str|
      r, w = IO.pipe
      Thread.new do # to avoid full pipe deadlocks
        begin
          w.write(str)
        rescue Errno::EPIPE
        ensure
          w.close
        end
      end
      r
    end
    result = yield *pipes
    pipes.each(&:close)
    result
  end

  def conditioned_output output
    # canonicalize based on how it looks - remove trailing whitespace, keep leading whitespace
    output.split("\n").map{|s|s.rstrip}.join("\n").rstrip << "\n"
  end
  
  def truncate_output output
    self.class.truncate_output(output)
  end

  def self.truncate_output output
    output.slice(0,100).split("\n",-1).take(10).join("\n").tap do |out|
      out << "..." if out.size < output.size
    end
  end
end
