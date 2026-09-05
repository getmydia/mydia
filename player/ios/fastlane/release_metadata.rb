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
