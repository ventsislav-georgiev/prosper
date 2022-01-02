NAME=Prosper
ID=com.ventsislav-georgiev.prosper
VERSION=0.0.0

.PHONY: info
info:
	@echo ${NAME} v${VERSION}

.PHONY: build-darwin
build-darwin: info
	@mkdir -p dist && cd dist \
	&& fyne package -os darwin -name ${NAME} -appVersion ${VERSION} -appID ${ID} -release -src ../ \
	&& plutil -insert LSUIElement -bool true Prosper.app/Contents/Info.plist

.PHONY: build-windows
build-windows: info
	@fyne package -os windows -name ${NAME} -appVersion ${VERSION} -appID ${ID} -release \
	&& mkdir -p dist && mv ${NAME}.exe dist/${NAME}.exe

.PHONY: install-darwin
install-darwin: build-darwin
	@cp -r dist/${NAME}.app /Applications
