.PHONY: build verify clean test python-test
.PHONY: xcode-generate xcode-verify-generated xcode-build xcode-sign xcode-run xcode-test xcode-smoke xcode-lifecycle-smoke

XCODE_DERIVED_DATA ?= build/NativDevelopmentDerivedData
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

build:
	python3 PythonDistribution/Scripts/build_mlx_vlm_server.py

verify:
	python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --verify-only

verify-python:
	python3 PythonDistribution/Scripts/build_mlx_vlm_server.py --skip-install --verify-only

clean:
	rm -rf build dist

test: python-test xcode-test

python-test:
	python3 -m unittest discover -s Tests/Python -v

xcode-generate:
	xcodegen generate

xcode-verify-generated: xcode-generate
	git diff --exit-code -- Nativ.xcodeproj/project.pbxproj

xcode-build: xcode-generate
	xcodebuild -project Nativ.xcodeproj -scheme Nativ -configuration Debug -derivedDataPath $(XCODE_DERIVED_DATA) CODE_SIGNING_ALLOWED=NO build

xcode-sign: xcode-build
	./scripts/sign_macos_debug.sh $(abspath $(XCODE_DERIVED_DATA)/Build/Products/Debug/Nativ.app)

xcode-run: xcode-sign
	./scripts/open_macos_debug.sh $(abspath $(XCODE_DERIVED_DATA)/Build/Products/Debug/Nativ.app)

xcode-test: xcode-generate
	xcodebuild -project Nativ.xcodeproj -scheme Nativ -configuration Debug -derivedDataPath $(XCODE_DERIVED_DATA) CODE_SIGNING_ALLOWED=NO test

xcode-smoke: xcode-build
	$(XCODE_DERIVED_DATA)/Build/Products/Debug/Nativ.app/Contents/MacOS/Nativ --smoke-test

xcode-lifecycle-smoke: xcode-build
	$(XCODE_DERIVED_DATA)/Build/Products/Debug/Nativ.app/Contents/MacOS/Nativ --lifecycle-smoke-test
