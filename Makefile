NAME=Prosper
ID=com.ventsislav-georgiev.prosper
VERSION=0.1.0

.PHONY: build-darwin
build-darwin:
	@mkdir -p dist && cd dist && fyne package -os darwin -name ${NAME} -appVersion ${VERSION} -appID ${ID} -release -src ../ \
	&& plutil -insert LSUIElement -bool true Prosper.app/Contents/Info.plist

.PHONY: install-darwin
install-darwin: build-darwin
	@cp -r dist/Prosper.app /Applications
