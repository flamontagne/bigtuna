require 'test_helper'

class ProjectTest < ActiveSupport::TestCase
  def setup
    super
    `cd test/files; mkdir repo; cd repo; git init; echo "my file" > file; git add file; git commit -m "my file added"`
  end

  def teardown
    FileUtils.rm_rf("test/files/repo")
    super
  end

  test "only recent builds are kept on disk" do
    project = project_with_steps({
      :name => "Project",
      :vcs_source => "test/files/repo",
      :max_builds => 1,
    }, "ls -al file")
    assert_difference("Dir[File.join(project.build_dir, '*')].size", +1) do
      project.build!
      run_delayed_jobs()
    end

    assert_difference("Dir[File.join(project.build_dir, '*')].size", 0) do
      project.build!
      run_delayed_jobs()
    end
  end

  test "removing project removes its builds" do
    project = project_with_steps({
      :name => "Project",
      :vcs_source => "test/files/repo",
      :max_builds => 1,
    }, "ls -al file")
    project.build!
    project.build!
    assert_difference("Build.count", -2) do
      project.destroy
    end
  end

  test "stdout is grouped by command" do
    project = project_with_steps({
      :name => "Project",
      :vcs_source => "test/files/repo",
      :max_builds => 1,
    }, "git diff file\necho 'lol'")
    project.build!
    run_delayed_jobs()
    build = project.recent_build
    steps = build.parts[0].output
    assert_equal 2, steps.size
    assert_equal "git diff file", steps[0].command
    assert_equal 0, steps[0].exit_code
    assert_equal "echo 'lol'", steps[1].command
    assert_equal 0, steps[1].exit_code
    assert_equal Build::STATUS_OK, build.status
  end

  test "build is stopped when task returns with non-zero exit code" do
    project = project_with_steps({
      :name => "Project",
      :vcs_source => "test/files/repo",
      :vcs_type => "git",
      :max_builds => 1,
    }, "ls -al file\nls -al not_a_file\necho 'not_here'")
    project.build!
    run_delayed_jobs()
    build = project.recent_build
    steps = build.parts[0].output
    assert_equal 3, steps.size # all steps, but not all were executed
    assert_equal "ls -al file", steps[0].command
    assert_equal 0, steps[0].exit_code
    assert_equal "ls -al not_a_file", steps[1].command
    assert steps[1].exit_code != 0
    assert_nil steps[2].exit_code
    assert_equal [], steps[2].stdout
    assert_equal "echo 'not_here'", steps[2].command
    assert_equal Build::STATUS_FAILED, build.status
  end

  test "removing project removes its build folder" do
    project = project_with_steps({
      :name => "Project",
      :vcs_source => "test/files/repo",
      :max_builds => 1,
    }, "ls -al file")
    project.build!
    run_delayed_jobs()
    assert File.exist?(project.build_dir)
    assert_difference("Dir[File.join('builds', '*')].size", -1) do
      project.destroy
    end
    assert ! File.exist?(project.build_dir)
  end

  test "hook_name should be unique" do
    hook_name = "my_unique_hook_name"
    Project.make(:hook_name => hook_name)
    assert_invalid(Project, :hook_name) { |p| p.hook_name = hook_name }
  end

  test "if hook_name is empty it can be not-unique" do
    Project.make(:hook_name => "")
    Project.make(:hook_name => "")
  end

  test "project name should be unique" do
    name = "unique project name"
    Project.make(:name => name)
    assert_invalid(Project, :name) { |p| p.name = name }
  end

  test "project name should be present" do
    assert_invalid(Project, :name) { |p| p.name = "" }
  end

  test "project dir should be renamed if project name changes" do
    project = project_with_steps({:name => "my name"}, "ls -al")
    dir = project.send(:build_dir_from_name, project.name)
    project.build!
    run_delayed_jobs()
    assert File.directory?(dir)
    project.name = "my other name"
    project.save!
    assert ! File.directory?(dir)
    project.build!
    run_delayed_jobs()
    new_dir = project.send(:build_dir_from_name, project.name)
    assert File.directory?(new_dir)
  end

  test "vcs_type should be one of vcs types available" do
    invalid_backend = "lol"
    assert_invalid(Project, :vcs_type) { |p| p.vcs_type = invalid_backend }
  end

  test "vcs_source should be present" do
    assert_invalid(Project, :vcs_source) { |p| p.vcs_source = "" }
  end

  test "vcs_branch should be present" do
    assert_invalid(Project, :vcs_branch) { |p| p.vcs_branch = "" }
  end

  test "total_builds gets increased" do
    project = project_with_steps({
      :name => "Project",
      :vcs_source => "test/files/repo",
      :max_builds => 1,
    }, "ls -al file")
    assert_equal 0, project.total_builds
    project.build!
    project.build!

    project.reload
    assert_equal 2, project.total_builds
  end

  test "stability is computed from recent 5 builds" do
    project = project_with_steps({
      :name => "Project",
      :vcs_source => "test/files/repo",
    }, "ls -al file")
    create_project_builds(project, Build::STATUS_OK, Build::STATUS_OK, Build::STATUS_OK, Build::STATUS_OK, Build::STATUS_FAILED, Build::STATUS_FAILED)
    assert_equal 4, project.stability
  end

  test "stability returns -1 not enough data if less than 5 builds" do
    project = project_with_steps({
      :name => "Project",
      :vcs_source => "test/files/repo",
    }, "ls -al file")
    create_project_builds(project, Build::STATUS_OK, Build::STATUS_FAILED, Build::STATUS_OK, Build::STATUS_OK)
    assert_equal -1, project.stability
  end

  test "stability doesn't include currently building or scheduled builds" do
    project = project_with_steps({
      :name => "Project",
      :vcs_source => "test/files/repo",
    }, "ls -al file")
    create_project_builds(project, Build::STATUS_FAILED, Build::STATUS_PROGRESS, Build::STATUS_IN_QUEUE, Build::STATUS_FAILED, Build::STATUS_OK, Build::STATUS_OK, Build::STATUS_FAILED)
    assert_equal 2, project.stability
  end

  test "build doesn't include empty or commented steps" do
    project = project_with_steps({
      :name => "Project",
      :vcs_source => "test/files/repo",
    }, "command1\ncommand2 #not3\n#not4\n     #not5\n")
    project.build!
    run_delayed_jobs()
    output = project.recent_build.parts[0].output
    assert_equal 2, output.count
    commands = output.map { |e| e.command }
    assert commands.include?('command1')
    assert commands.include?('command2')
    assert ! commands.include?('command2 #not3')
    assert ! commands.include?('#not4')
    assert ! commands.include?('#not5')
  end

  test "invoking #build! cancels previously queued build" do
    project = project_with_steps({:vcs_source => "test/files/repo"}, "true", "true\nfalse")
    assert_difference("Delayed::Job.count", +1) do
      3.times { project.build! }
    end
  end

  private
  def create_project_builds(project, *statuses)
    statuses.reverse.each do |status|
      project.build!
      project.reload
      build = project.recent_build
      build.update_attributes!(:status => status)
    end
  end
end
