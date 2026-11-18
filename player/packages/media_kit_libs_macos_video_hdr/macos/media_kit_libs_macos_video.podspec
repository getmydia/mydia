#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint media_kit_libs_macos_video.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  # A failed download, checksum or extraction must stop `pod install` here,
  # not leave it to vendor frameworks that are not there.
  system("make") or raise "media_kit_libs_macos_video: make failed preparing the libmpv frameworks"

  s.name             = 'media_kit_libs_macos_video'
  s.version          = '1.1.4-hdr'
  s.summary          = 'macOS dependency package for package:media_kit'
  s.description      = <<-DESC
  macOS dependency package for package:media_kit.
                       DESC
  s.homepage         = 'https://github.com/getmydia/libmpv-darwin-build'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Hitesh Kumar Saini' => 'saini123hitesh@gmail.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.vendored_frameworks = 'Frameworks/*.xcframework'

  s.platform = :osx, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
