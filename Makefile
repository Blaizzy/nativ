.PHONY: build verify clean
.PHONY: xcode-generate xcode-build xcode-sign xcode-run xcode-smoke xcode-lifecycle-smoke

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

xcode-generate:
	xcodegen generate

xcode-build: xcode-generate
	xcodebuild -project Nativ.xcodeproj -scheme Nativ -configuration Debug -derivedDataPath $(XCODE_DERIVED_DATA) CODE_SIGNING_ALLOWED=NO build

xcode-sign: xcode-build
	./scripts/sign_macos_debug.sh $(abspath $(XCODE_DERIVED_DATA)/Build/Products/Debug/Nativ.app)

xcode-run: xcode-sign
	./scripts/open_macos_debug.sh $(abspath $(XCODE_DERIVED_DATA)/Build/Products/Debug/Nativ.app)

xcode-smoke: xcode-build
	$(XCODE_DERIVED_DATA)/Build/Products/Debug/Nativ.app/Contents/MacOS/Nativ --smoke-test

xcode-lifecycle-smoke: xcode-build
	$(XCODE_DERIVED_DATA)/Build/Products/Debug/Nativ.app/Contents/MacOS/Nativ --lifecycle-smoke-test
