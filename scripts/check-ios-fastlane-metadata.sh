#!/usr/bin/env bash
#
# Assert the iOS fastlane metadata helpers behave, using the system ruby.
#
# A Fastfile only loads under fastlane, so these two functions live in their own
# plain-Ruby file to be testable here. ci-fastlane.yml separately proves the
# Fastfile still parses and that the file is reachable via require_relative;
# this proves the logic inside it.
set -euo pipefail
export LC_ALL=C.UTF-8

cd "$(dirname "$0")/.."

ruby - "player/ios/fastlane/release_metadata.rb" <<'RUBY'
require File.expand_path(ARGV[0])
require "tempfile"

failures = []
check = lambda do |desc, got, want|
  failures << "#{desc}: got #{got.inspect}, wanted #{want.inspect}" unless got == want
end

# Group names are matched exactly by App Store Connect, so the hyphen and the
# capital P in "Pre-release" are load-bearing.
ENV.delete("TESTFLIGHT_GROUPS")
check.call("unset falls back to the pre-split group", testflight_groups, ["Beta"])

ENV["TESTFLIGHT_GROUPS"] = ""
check.call("empty falls back", testflight_groups, ["Beta"])

ENV["TESTFLIGHT_GROUPS"] = "Pre-release"
check.call("a prerelease reaches one group", testflight_groups, ["Pre-release"])

ENV["TESTFLIGHT_GROUPS"] = "Beta,Pre-release"
check.call("a stable release reaches both", testflight_groups, ["Beta", "Pre-release"])

ENV["TESTFLIGHT_GROUPS"] = " Beta , Pre-release "
check.call("whitespace is trimmed", testflight_groups, ["Beta", "Pre-release"])

ENV["TESTFLIGHT_GROUPS"] = "Beta,,Pre-release"
check.call("empty entries are dropped", testflight_groups, ["Beta", "Pre-release"])

# Apple refuses an empty "What to Test" for external distribution, so every
# failure mode here has to land on the literal rather than on "".
ENV.delete("TESTFLIGHT_CHANGELOG_PATH")
check.call("no notes path", testflight_changelog, "Automated beta build.")

ENV["TESTFLIGHT_CHANGELOG_PATH"] = ""
check.call("empty notes path", testflight_changelog, "Automated beta build.")

ENV["TESTFLIGHT_CHANGELOG_PATH"] = "/nonexistent/notes.txt"
check.call("unreadable notes path", testflight_changelog, "Automated beta build.")

blank = Tempfile.new("notes")
blank.write("   \n\n")
blank.flush
ENV["TESTFLIGHT_CHANGELOG_PATH"] = blank.path
check.call("blank notes file", testflight_changelog, "Automated beta build.")

real = Tempfile.new("notes")
real.write("\nWhat changed.\n\n")
real.flush
ENV["TESTFLIGHT_CHANGELOG_PATH"] = real.path
check.call("real notes are read and stripped", testflight_changelog, "What changed.")

if failures.empty?
  puts "ios fastlane metadata: all cases pass"
else
  failures.each { |f| warn "FAIL: #{f}" }
  exit 1
end
RUBY
