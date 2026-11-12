.PHONY: bootstrap test project build-ios build-bridge package-unsigned-ipa publish-sidestore-source publish-cos-release verify clean

bootstrap:
	./scripts/bootstrap-upstream.sh
	swift package --package-path Packages/FirepickKit resolve

test:
	swift test --package-path Packages/FirepickKit

project:
	xcodegen generate

build-ios: project
	xcodebuild \
		-project Firepick.xcodeproj \
		-scheme Firepick \
		-sdk iphoneos \
		-destination 'generic/platform=iOS' \
		-derivedDataPath "$(CURDIR)/.build/ios" \
		-clonedSourcePackagesDirPath "$(CURDIR)/Packages/FirepickKit/.build" \
		-disableAutomaticPackageResolution \
		CODE_SIGNING_ALLOWED=NO \
		build

build-bridge:
	./scripts/build-bridge.sh

package-unsigned-ipa:
	./scripts/package-unsigned-ipa.sh

publish-sidestore-source:
	./scripts/publish-sidestore-source.sh "$(VERSION)" "$(PUBLIC_BASE_URL)"

publish-cos-release:
	./scripts/publish-cos-release.sh "$(VERSION)" "$(COS_BUCKET)" "$(COS_REGION)"

verify:
	./scripts/verify.sh

clean:
	rm -rf .build Packages/FirepickKit/.build Firepick.xcodeproj

