require "spec"
require "./spec_helper"

describe "exit" do
  it "exits normally with status 0" do
    status, _, _ = compile_and_run_source "exit"
    status.success?.should be_true
  end

  it "exits with given error code" do
    status, _, _ = compile_and_run_source "exit 42"
    status.success?.should be_false
    status.exit_code.should eq(42)
  end
end

describe "at_exit" do
  it "runs handlers on normal program ending" do
    status, output, _ = compile_and_run_source <<-CODE
      at_exit do
        puts "handler code"
      end
    CODE

    status.success?.should be_true
    output.should eq("handler code\n")
  end

  it "runs handlers on explicit program ending" do
    status, output, _ = compile_and_run_source <<-'CODE'
      at_exit do |exit_code|
        puts "handler code, exit code: #{exit_code}"
      end

      exit 42
    CODE

    status.exit_code.should eq(42)
    output.should eq("handler code, exit code: 42\n")
  end

  it "runs handlers in reverse order" do
    status, output, _ = compile_and_run_source <<-CODE
      at_exit do
        puts "first handler code"
      end

      at_exit do
        puts "second handler code"
      end
    CODE

    status.success?.should be_true
    output.should eq <<-OUTPUT
                       second handler code
                       first handler code

                       OUTPUT
  end

  it "runs all handlers maximum once" do
    status, output, _ = compile_and_run_source <<-CODE
      at_exit do
        puts "first handler code"
      end

      at_exit do
        puts "second handler code, explicit exit!"
        exit

        puts "not executed"
      end

      at_exit do
        puts "third handler code"
      end
    CODE

    status.success?.should be_true
    output.should eq <<-OUTPUT
                       third handler code
                       second handler code, explicit exit!
                       first handler code

                       OUTPUT
  end

  it "allows handlers to change the exit code with explicit `exit` call" do
    status, output, _ = compile_and_run_source <<-'CODE'
      at_exit do |exit_code|
        puts "first handler code, exit code: #{exit_code}"
      end

      at_exit do
        puts "second handler code, re-exiting"
        exit 42

        puts "not executed"
      end

      at_exit do |exit_code|
        puts "third handler code, exit code: #{exit_code}"
      end
    CODE

    status.success?.should be_false
    status.exit_code.should eq(42)
    output.should eq <<-OUTPUT
                       third handler code, exit code: 0
                       second handler code, re-exiting
                       first handler code, exit code: 42

                       OUTPUT
  end

  it "allows handlers to change the exit code with explicit `exit` call (2)" do
    status, output, _ = compile_and_run_source <<-'CODE'
      at_exit do |exit_code|
        puts "first handler code, exit code: #{exit_code}"
      end

      at_exit do
        puts "second handler code, re-exiting"
        exit 42

        puts "not executed"
      end

      at_exit do |exit_code|
        puts "third handler code, exit code: #{exit_code}"
      end

      exit 21
    CODE

    status.success?.should be_false
    status.exit_code.should eq(42)
    output.should eq <<-OUTPUT
                       third handler code, exit code: 21
                       second handler code, re-exiting
                       first handler code, exit code: 42

                       OUTPUT
  end

  it "changes final exit code when an handler raises an error" do
    status, output, error = compile_and_run_source <<-'CODE'
      at_exit do |exit_code|
        puts "first handler code, exit code: #{exit_code}"
      end

      at_exit do
        puts "second handler code, raising"
        raise "Raised from at_exit handler!"

        puts "not executed"
      end

      at_exit do |exit_code|
        puts "third handler code, exit code: #{exit_code}"
      end
    CODE

    status.success?.should be_false
    status.exit_code.should eq(1)
    output.should eq <<-OUTPUT
                       third handler code, exit code: 0
                       second handler code, raising
                       first handler code, exit code: 1

                       OUTPUT
    error.should eq "Error running at_exit handler: Raised from at_exit handler!\n"
  end

  it "shows unhandled exceptions after at_exit handlers" do
    status, _, error = compile_and_run_source <<-CODE
      at_exit do
        STDERR.puts "first handler code"
      end

      at_exit do
        STDERR.puts "second handler code"
      end

      raise "Kaboom!"
    CODE

    status.success?.should be_false
    error.should contain <<-OUTPUT
                           second handler code
                           first handler code
                           Unhandled exception: Kaboom!
                           OUTPUT
  end

  it "can get unhandled exception in at_exit handler" do
    status, _, error = compile_and_run_source <<-CODE
      at_exit do |_, ex|
        STDERR.puts ex.try &.message
      end

      raise "Kaboom!"
    CODE

    status.success?.should be_false
    error.should contain <<-OUTPUT
                           Kaboom!
                           Unhandled exception: Kaboom!
                           OUTPUT
  end

  it "allows at_exit inside at_exit" do
    status, output, _ = compile_and_run_source <<-CODE
      at_exit do
        puts "1"
        at_exit do
          puts "2"
        end
      end

      at_exit do
        puts "3"
        at_exit do
          puts "4"
        end
      end
    CODE

    status.success?.should be_true
    output.should eq("3\n4\n1\n2\n")
  end

  it "prints unhandled exception with cause" do
    status, _, error = compile_and_run_source <<-CODE
      raise Exception.new("secondary", cause: Exception.new("primary"))
    CODE

    status.success?.should be_false
    error.should contain "Unhandled exception: secondary"
    error.should contain "Caused by: primary"
  end
end

describe "seg fault" do
  it "reports SIGSEGV" do
    status, _, error = compile_and_run_source <<-'CODE'
      puts Pointer(Int64).null.value
    CODE

    status.success?.should be_false
    error.should contain("Invalid memory access")
    error.should_not contain("Stack overflow")
  end

  {% if flag?(:musl) %}
    # FIXME: Pending as mitigation for https://github.com/crystal-lang/crystal/issues/7482
    pending "detects stack overflow on the main stack"
  {% else %}
    it "detects stack overflow on the main stack" do
      # This spec can take some time under FreeBSD where
      # the default stack size is 0.5G.  Setting a
      # smaller stack size with `ulimit -s 8192`
      # will address this.
      status, _, error = compile_and_run_source <<-'CODE'
      def foo
        y = StaticArray(Int8,512).new(0)
        foo
      end
      foo
    CODE

      status.success?.should be_false
      error.should contain("Stack overflow")
    end
  {% end %}

  it "detects stack overflow on a fiber stack" do
    status, _, error = compile_and_run_source <<-'CODE'
      def foo
        y = StaticArray(Int8,512).new(0)
        foo
      end

      spawn do
        foo
      end

      sleep 60.seconds
    CODE

    status.success?.should be_false
    error.should contain("Stack overflow")
  end
end
