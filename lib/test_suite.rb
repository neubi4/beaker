# -*- coding: utf-8 -*-
require 'rexml/document'

# This Class is in need of some cleaning up beyond what can be quickly done.
# Things to keep in mind:
#   * Global State Change
#   * File Creation Relative to CWD  -- Should be a config option
#   * Better Method Documentation
class TestSuite
  attr_reader :name, :options, :config, :stop_on_error

  def initialize(name, hosts, options, config, stop_on_error=FALSE)
    @name    = name.gsub(/\s+/, '-')
    @hosts   = hosts
    @run     = false
    @options = options
    @config  = config
    @stop_on_error = stop_on_error

    @test_cases = []
    @test_files = []

    Array(options[:tests] || 'tests').each do |root|
      if File.file? root then
        @test_files << root
      else
        @test_files += Dir.glob(
          File.join(root, "**/*.rb")
        ).select { |f| File.file?(f) }
      end
    end
    fail "no test files found..." if @test_files.empty?

    if options[:random]
      @random_seed = (options[:random] == true ? Time.now : options[:random]).to_i
      srand @random_seed
      @test_files = @test_files.sort_by { rand }
    else
      @test_files = @test_files.sort
    end
  end

  def run
    @run = true
    @start_time = Time.now

    initialize_logfiles

    Log.notify "Using random seed #{@random_seed}" if @random_seed
    @test_files.each do |test_file|
      Log.notify
      Log.notify "Begin #{test_file}"
      start = Time.now
      test_case = TestCase.new(@hosts, config, options, test_file).run_test
      duration = Time.now - start
      @test_cases << test_case

      state = test_case.test_status == :skip ? 'skipp' : test_case.test_status
      msg = "#{test_file} #{state}ed in %.2f seconds" % duration.to_f
      case test_case.test_status
      when :pass
        Log.success msg
      when :skip
        Log.debug msg
      when :fail
        Log.error msg
        break if stop_on_error
      when :error
        Log.warn msg
        break if stop_on_error
      end
    end

    # REVISIT: This changes global state, breaking logging in any future runs
    # of the suite – or, at least, making them highly confusing for anyone who
    # has not studied the implementation in detail. --daniel 2011-03-14
    summarize
    write_junit_xml if options[:xml]

    # Allow chaining operations...
    return self
  end

  def run_and_exit_on_failure
    run
    return self if success?
    Log.error "Failed while running the #{name} suite..."
    exit 1
  end

  def fail_without_test_run
    fail "you have not run the tests yet" unless @run
  end

  def success?
    fail_without_test_run
    sum_failed == 0
  end

  def failed?
    !success?
  end

  def test_count
    @test_count ||= @test_cases.length
  end

  def passed_tests
    @passed_tests ||= @test_cases.select { |c| c.test_status == :pass }.length
  end

  def errored_tests
    @errored_tests ||= @test_cases.select { |c| c.test_status == :error }.length
  end

  def failed_tests
    @failed_tests ||= @test_cases.select { |c| c.test_status == :fail }.length
  end

  def skipped_tests
    @skipped_tests ||= @test_cases.select { |c| c.test_status == :skip }.length
  end

  def pending_tests
    @pending_tests ||= @test_cases.select {|c| c.test_status == :pending}.length
  end

  private

  def sum_failed
    @sum_failed ||= failed_tests + errored_tests
  end

  def write_junit_xml
    # This should be a configuration option
    File.directory?('junit') or FileUtils.mkdir('junit')

    begin
      doc   = REXML::Document.new
      doc.add(REXML::XMLDecl.new(1.0))

      suite = REXML::Element.new('testsuite', doc)
      suite.add_attribute('name',     name)
      suite.add_attribute('tests',    test_count)
      suite.add_attribute('errors',   errored_test)
      suite.add_attribute('failures', failed_test)
      suite.add_attribute('skip',     skipped_test)
      suite.add_attribute('pending',  pending_tests)

      @test_cases.each do |test|
        item = REXML::Element.new('testcase', suite)
        item.add_attribute('classname', File.dirname(test.path))
        item.add_attribute('name',      File.basename(test.path))
        item.add_attribute('time',      test.runtime)

        # Did we fail?  If so, report that.
        if test.test_status == :fail || test.test_status == :error then
          status = REXML::Element.new('failure', item)
          status.add_attribute('type', test.test_status.to_s)
          if test.exception then
            status.add_attribute('message', test.exception.to_s)
            status.text = test.exception.backtrace.join("\n")
          end
        end

        if test.stdout then
          REXML::Element.new('system-out', item).text =
            test.stdout.gsub(/[\0-\011\013\014\016-\037]/) {|c| "&#{c[0]};" }
        end

        if test.stderr then
          text = REXML::Element.new('system-err', item)
          text.text = test.stderr.gsub(/[\0-\011\013\014\016-\037]/) {|c| "&#{c[0]};" }
        end
      end

      # junit/name.xml will be created in a directory relative to the CWD
      # --  JLS 2/12
      File.open("junit/#{name}.xml", 'w') { |fh| doc.write(fh) }
    rescue Exception => e
      Log.error "failure in XML output:\n#{e.to_s}\n" + e.backtrace.join("\n")
    end
  end

  def summarize
    fail_without_test_run

    if Log.file then
      Log.file = log_path("#{name}-summary.txt")
    end
    Log.stdout = true

    Log.notify <<-HEREDOC
  Test Suite: #{name} @ #{@start_time}

  - Host Configuration Summary -
    HEREDOC

    TestConfig.dump(config)

    elapsed_time = @test_cases.inject(0.0) {|r, t| r + t.runtime.to_f }
    average_test_time = elapsed_time / test_count

    Log.notify %Q[

          - Test Case Summary -
   Total Suite Time: %.2f seconds
  Average Test Time: %.2f seconds
          Attempted: #{test_count}
             Passed: #{passed_tests}
             Failed: #{failed_tests}
            Errored: #{errored_tests}
            Skipped: #{skipped_tests}
            Pending: #{pending_tests}

  - Specific Test Case Status -
    ] % [elapsed_time, average_test_time]

    grouped_summary = @test_cases.group_by{|test_case| test_case.test_status }

    Log.notify "Failed Tests Cases:"
    (grouped_summary[:fail] || []).each do |test_case|
      print_test_failure(test_case)
    end

    Log.notify "Errored Tests Cases:"
    (grouped_summary[:error] || []).each do |test_case|
      print_test_failure(test_case)
    end

    Log.notify "Skipped Tests Cases:"
    (grouped_summary[:skip] || []).each do |test_case|
      print_test_failure(test_case)
    end

    Log.notify "Pending Tests Cases:"
    (grouped_summary[:pending] || []).each do |test_case|
      print_test_failure(test_case)
    end

    Log.notify("\n\n")

    Log.stdout = !options[:quiet]
    Log.file   = false
  end

  def print_test_failure(test_case)
    test_reported = if test_case.exception
                      "reported: #{test_case.exception.inspect}"
                    else
                      test_case.test_status
                    end
    Log.notify "  Test Case #{test_case.path} #{test_reported}"
  end

  def log_path(name)
    @@log_dir ||= File.join("log", @start_time.strftime("%F_%T"))
    unless File.directory?(@@log_dir) then
      FileUtils.mkdir(@@log_dir)
      FileUtils.cp(options[:config],(File.join(@@log_dir,"config.yml")))

      latest = File.join("log", "latest")
      if !File.exist?(latest) or File.symlink?(latest) then
        File.delete(latest) if File.exist?(latest)
        File.symlink(File.basename(@@log_dir), latest)
      end
    end

    File.join('log', 'latest', name)
  end

  # Setup log dir
  def initialize_logfiles
    return if options[:stdout_only]
    Log.file = log_path("#{name}-run.log")
  end
end
