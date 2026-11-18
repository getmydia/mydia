# Each step ends by touching its own stamp, only once every command before
# it succeeded. A step that failed halfway (a full disk during tar, a broken
# link script) leaves no stamp, so the next build clears it and runs again
# instead of taking the partial output as up to date.
all: Frameworks/.extracted Frameworks/.linked

MPV_VARIANT=video-hdr
MPV_XCFRAMEWORKS_VERSION=v0.7.3-mydia.3
MPV_XCFRAMEWORKS_SHA256SUM=ffe80134c8fafec61d35be24dd2fb2fc78656f23d778768df460ef788eb1b1c5

.cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal-${MPV_VARIANT}.tar.gz:
	mkdir -p .cache/xcframeworks
	rm -f .cache/xcframeworks/*.tmp .cache/xcframeworks/*.tar.gz
	curl -L \
		https://github.com/getmydia/libmpv-darwin-build/releases/download/${MPV_XCFRAMEWORKS_VERSION}/libmpv-xcframeworks_${MPV_XCFRAMEWORKS_VERSION}_macos-universal-${MPV_VARIANT}.tar.gz \
		-o .cache/xcframeworks/libmpv.tar.gz.tmp
	shasum -a 256 -c <<< '${MPV_XCFRAMEWORKS_SHA256SUM}  .cache/xcframeworks/libmpv.tar.gz.tmp'
	mv .cache/xcframeworks/libmpv.tar.gz.tmp .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal-${MPV_VARIANT}.tar.gz
	touch .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal-${MPV_VARIANT}.tar.gz

.cache/xcframeworks/libmpv-xcframeworks-macos-universal-${MPV_VARIANT}.tar.gz: .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal-${MPV_VARIANT}.tar.gz
	rm -f .cache/xcframeworks/libmpv-xcframeworks-macos-universal-${MPV_VARIANT}.tar.gz
	ln -s libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal-${MPV_VARIANT}.tar.gz .cache/xcframeworks/libmpv-xcframeworks-macos-universal-${MPV_VARIANT}.tar.gz

Frameworks/.extracted: .cache/xcframeworks/libmpv-xcframeworks-macos-universal-${MPV_VARIANT}.tar.gz
	rm -rf Frameworks
	mkdir -p Frameworks
	tar -xvf .cache/xcframeworks/libmpv-xcframeworks-macos-universal-${MPV_VARIANT}.tar.gz --strip-components 1 -C Frameworks
	test -d Frameworks/Mpv.xcframework
	touch Frameworks/.extracted

Frameworks/.linked: Frameworks/.extracted
	rm -rf Frameworks/.symlinks Frameworks/.linked
	mkdir -p Frameworks/.symlinks/mpv
	sed -i '' 's/\r$$//g' create_framework_symlinks.sh # remove CRLF line terminator added by Flutter packaging (https://github.com/media-kit/media-kit/issues/338)
	sh create_framework_symlinks.sh Frameworks/Mpv.xcframework Frameworks/.symlinks/mpv
	touch Frameworks/.linked

.PHONY: clean
clean:
	rm -rf .cache
	rm -f ./Headers/mpv/*.h
	rm -rf ./Frameworks
