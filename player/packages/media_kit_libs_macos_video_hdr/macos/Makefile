all: Frameworks/*.xcframework Frameworks/.symlinks

MPV_VARIANT=video-hdr
MPV_XCFRAMEWORKS_VERSION=v0.7.3-mydia.2
MPV_XCFRAMEWORKS_SHA256SUM=b0e16c34b8ad2413cd749b190f8464f9fce3795c33630df763eb19b3abaf2b4f

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

Frameworks/*.xcframework: .cache/xcframeworks/libmpv-xcframeworks-macos-universal-${MPV_VARIANT}.tar.gz
	mkdir -p Frameworks
	rm -rf Frameworks/*.xcframework
	tar -xvf .cache/xcframeworks/libmpv-xcframeworks-macos-universal-${MPV_VARIANT}.tar.gz --strip-components 1 -C Frameworks
	touch Frameworks/*.xcframework

Frameworks/.symlinks: Frameworks/*.xcframework
	rm -rf Frameworks/.symlinks
	mkdir -p Frameworks/.symlinks/mpv
	sed -i '' 's/\r$$//g' create_framework_symlinks.sh # remove CRLF line terminator added by Flutter packaging (https://github.com/media-kit/media-kit/issues/338)
	sh create_framework_symlinks.sh Frameworks/Mpv.xcframework Frameworks/.symlinks/mpv

.PHONY: clean
clean:
	rm -rf .cache
	rm -f ./Headers/mpv/*.h
	rm -rf ./Frameworks/*.xcframework
