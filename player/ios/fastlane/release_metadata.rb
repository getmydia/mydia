# frozen_string_literal: true
#
# Metadata the TestFlight upload needs, derived from the environment that
# release.yml and player-ios-refresh.yml set.
#
# Extracted from the Fastfile so it can be tested with plain ruby: a Fastfile
# only loads under fastlane, which needs bundler and the full gem set.
# scripts/check-ios-fastlane-metadata.sh covers everything here.

# What testers read in TestFlight. The workflow writes the release's `## Player`
# notes to a file and names it here. The literal fallback keeps a local run
# working with nothing set up, and degrades a failed write to the old behaviour
# rather than to a rejected upload: Apple refuses an empty "What to Test" for
# external distribution.
def testflight_changelog
  path = ENV["TESTFLIGHT_CHANGELOG_PATH"]
  return "Automated beta build." if path.nil? || path.empty? || !File.readable?(path)

  notes = File.read(path).strip
  notes.empty? ? "Automated beta build." : notes
end

# Which App Store Connect external groups this build reaches. The workflow sets
# TESTFLIGHT_GROUPS from `is_prerelease`: a prerelease reaches only the
# pre-release group, a stable release reaches both, so a pre-release tester
# receives a stable release as an ordinary update rather than sitting on a beta
# until the next cycle opens.
#
# App Store Connect matches a group by exact name. "Pre-release" carries a
# hyphen and a capital P because that is how the group is named in the account.
# "Prerelease" is a different, non-existent group, and naming it fails the
# upload.
#
# The fallback is the behaviour from before the split, so a bare local run still
# works with nothing set up.
def testflight_groups
  groups = ENV["TESTFLIGHT_GROUPS"].to_s.split(",").map(&:strip).reject(&:empty?)
  groups.empty? ? ["Beta"] : groups
end

# Whether to distribute to external TestFlight groups. When false, uploads for
# internal testers only and skips waiting for Apple Beta App Review.
def testflight_distribute_external?
  ENV.fetch("TESTFLIGHT_DISTRIBUTE_EXTERNAL", "true") == "true"
end

# The highest of a list of CFBundleVersion strings, compared the way App Store
# Connect compares them: period-separated integers, one by one, so 17000042.10
# beats 17000042.9 and 17000043 beats both. The `highest_build_number` lane
# feeds it every build the app has uploaded; a branch build is numbered just
# above the result (scripts/branch-build-number.sh).
#
# Raises on a value that is not up to three period-separated integers rather
# than skipping it: a number this cannot read might be the highest, and a guess
# below it would be rejected at upload. Returns nil for an empty list.
def max_build_number(versions)
  parsed = versions.map do |v|
    s = v.to_s.strip
    raise ArgumentError, "unreadable build number #{v.inspect}" unless s.match?(/\A\d+(\.\d+){0,2}\z/)

    s.split(".").map(&:to_i)
  end
  parsed.max&.join(".")
end
