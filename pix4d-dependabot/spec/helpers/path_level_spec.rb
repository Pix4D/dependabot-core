# frozen_string_literal: true

require "helpers/path_level"
require_relative "spec_helper"

RSpec.describe "recursive_path", :pix4d do
  context "using a concourse feature_package" do
    it "returns the correct project_path" do
      project_data = {
        "module" => "concourse",
        "repo" => "Pix4D/dependabot",
        "branch" => "master",
        "dependency_dir" => "ci/pipelines"
      }
      expect(recursive_path(project_data, "token")).to eq(["ci/pipelines"])
    end
  end

  context "using a docker feature_package" do
    let(:project_path) { "Pix4D/dependabot" }
    let(:github_sha) { "76abc" }
    let(:project_data) do
      {
        "module" => "docker",
        "repo" => project_path,
        "branch" => "master",
        "dependency_dir" => "dockerfiles"
      }
    end
    let(:branch) { project_data["branch"] }
    let(:github_url) { "https://api.github.com/" }
    let(:url1) { github_url + "repos/#{project_path}/branches/#{branch}" }
    let(:url2) do
      github_url +
        "repos/#{project_path}/git/trees/#{github_sha}?recursive=true"
    end
    before do
      stub_request(:get, url1).
        to_return(
          status: 200,
          body: { "name": branch, "commit": { "sha": github_sha } }.to_json,
          headers: { "content-type" => "application/json" }
        )
      stub_request(:get, url2).
        to_return(
          status: 200,
          body: { "sha": github_sha, "tree": [
            { "path": "dockerfiles/folder-1/Dockerfile" },
            { "path": "dockerfiles/folder-2/Dockerfile" },
            { "path": "dockerfiles/folder-2/code.py" },
            { "path": "ci/pipeline-template.ymls" }
          ] }.to_json,
          headers: { "content-type" => "application/json" }
        )
    end

    it "returns the correct project_path" do
      expect(recursive_path(project_data, "token")).
        to eq(["dockerfiles/folder-1", "dockerfiles/folder-2"])
    end
  end

  context "using a docker feature_package" do
    let(:github_url) { "https://api.github.com/" }
    let(:url1) { github_url + "repos/#{project_path}/branches/master" }
    let(:project_path) { "Pix4D/non-existing" }
    let(:project_data) do
      {
        "module" => "docker",
        "repo" => project_path,
        "branch" => "master",
        "dependency_dir" => "dependency_dir"
      }
    end
    before do
      stub_request(:get, url1).
        to_return(
          status: 404,
          body: { "message": "not found" }.to_json,
          headers: { "content-type" => "application/json" }
        )
    end

    it "raises a correct error (repo not found)" do
      expect { recursive_path(project_data, "token") }.
        to raise_error(Octokit::NotFound, "GET #{url1}: 404 - not found")
    end
  end

  context "using a docker feature_package" do
    let(:github_url) { "https://api.github.com/" }
    let(:url1) { github_url + "repos/#{project_path}/branches/master" }
    let(:url2) do
      github_url +
        "repos/#{project_path}/git/trees/#{github_sha}?recursive=true"
    end
    let(:project_path) { "Pix4D/dependabot" }
    let(:dependency_dir) { "dockerfiles" }
    let(:github_sha) { "76abc" }
    let(:project_data) do
      {
        "module" => "docker",
        "repo" => project_path,
        "branch" => "master",
        "dependency_dir" => dependency_dir
      }
    end

    before do
      stub_request(:get, url1).
        to_return(
          status: 200,
          body: { "name": "master", "commit": { "sha": github_sha } }.to_json,
          headers: { "content-type" => "application/json" }
        )
      stub_request(:get, url2).
        to_return(
          status: 404,
          body: { "message": "not found" }.to_json,
          headers: { "content-type" => "application/json" }
        )
    end

    it "raises a correct error (tree not found)" do
      expect { recursive_path(project_data, "token") }.
        to raise_error(Octokit::NotFound, "GET #{url2}: 404 - not found")
    end
  end
end
