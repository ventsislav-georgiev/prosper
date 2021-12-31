package open

import (
	"bytes"
	"image"
	"image/png"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/groob/plist"
	"github.com/iineva/bom/pkg/asset"
	"github.com/sahilm/fuzzy"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"yrh.dev/icns"
)

const (
	darwinUserAppsPath = "/Applications"
	darwinSysAppsPath  = "/System/Applications"
)

type fuzzySource []ExecInfo

func (f fuzzySource) String(i int) string {
	return f[i].DisplayName
}

func (f fuzzySource) Len() int {
	return len(f)
}

type ExecInfo struct {
	DisplayName string
	Filename    string
	Path        string
}

func (e *ExecInfo) Exec() {
	exec.Command("open", e.Filepath()).Run()
}

func (e *ExecInfo) Filepath() string {
	return filepath.Join(e.Path, e.Filename)
}

func Eval(expr string) (s string, icon []byte, onEnter func(), err error) {
	if runtime.GOOS != "darwin" {
		return "", nil, nil, helpers.ErrSkip
	}

	if !strings.HasPrefix(expr, "o ") {
		return "", nil, nil, helpers.ErrSkip
	}

	name := strings.ToLower(expr[2:])

	app, err := EvalWithoutIcon(name)
	if err != nil {
		return app.DisplayName, nil, onEnter, nil
	}

	return EvalWithIcon(app)
}

func EvalWithoutIcon(name string) (a ExecInfo, err error) {
	userApps, err := os.ReadDir(darwinUserAppsPath)
	if err != nil {
		return ExecInfo{}, nil
	}

	sysApps, err := os.ReadDir(darwinSysAppsPath)
	if err != nil {
		return ExecInfo{}, nil
	}

	var apps fuzzySource = make([]ExecInfo, 0, len(userApps)+len(sysApps))
	for _, f := range userApps {
		apps = append(apps, ExecInfo{DisplayName: strings.TrimSuffix(f.Name(), ".app"), Path: darwinUserAppsPath, Filename: f.Name()})
	}
	for _, f := range sysApps {
		apps = append(apps, ExecInfo{DisplayName: strings.TrimSuffix(f.Name(), ".app"), Path: darwinSysAppsPath, Filename: f.Name()})
	}

	matches := fuzzy.FindFrom(name, apps)
	if len(matches) == 0 {
		return ExecInfo{}, nil
	}

	app := apps[matches[0].Index]

	return app, nil
}

func EvalWithIcon(app ExecInfo) (s string, icon []byte, onEnter func(), err error) {
	onEnter = func() {
		app.Exec()
	}

	appPath := filepath.Join(app.Path, app.Filename)

	info, err := ioutil.ReadFile(filepath.Join(appPath, "Contents", "Info.plist"))
	if err != nil {
		return app.DisplayName, nil, onEnter, nil
	}

	var bundleHeader struct {
		CFBundleIconFile string `plist:"CFBundleIconFile"`
		CFBundleIconName string `plist:"CFBundleIconName"`
	}

	err = plist.Unmarshal(info, &bundleHeader)
	if err != nil {
		return app.DisplayName, nil, onEnter, nil
	}

	if bundleHeader.CFBundleIconFile == "" && bundleHeader.CFBundleIconName == "" {
		return app.DisplayName, nil, onEnter, nil
	}

	var img image.Image
	resPath := filepath.Join(app.Path, app.Filename, "Contents", "Resources")

	if bundleHeader.CFBundleIconFile != "" {
		if !strings.HasSuffix(bundleHeader.CFBundleIconFile, ".icns") {
			bundleHeader.CFBundleIconFile += ".icns"
		}
		img, err = getImageFromIcns(bundleHeader.CFBundleIconFile, resPath)
	}

	if img == nil && bundleHeader.CFBundleIconName != "" {
		img, err = getImageFromAssetsCar(bundleHeader.CFBundleIconName, resPath)
	}

	if err != nil || img == nil {
		return app.DisplayName, nil, onEnter, nil
	}

	var buf bytes.Buffer
	err = png.Encode(&buf, img)
	if err != nil {
		return app.DisplayName, nil, onEnter, nil
	}

	return app.DisplayName, buf.Bytes(), onEnter, nil
}

func getImageFromIcns(cfBundleIconFile string, resPath string) (img image.Image, err error) {
	imgBytes, err := ioutil.ReadFile(filepath.Join(resPath, cfBundleIconFile))
	if err != nil {
		return nil, err
	}

	icnsFile, err := icns.Decode(bytes.NewReader(imgBytes))
	if err != nil {
		return nil, err
	}

	desiredRes := []icns.Resolution{icns.Pixel128, icns.Pixel256, icns.Pixel512, icns.Pixel64, icns.Pixel48, icns.Pixel32}
	for _, r := range desiredRes {
		img, err = icnsFile.ByResolution(r)
		if err == nil {
			break
		}
	}

	if img == nil {
		img, err = icnsFile.HighestResolution()
	}

	return
}

func getImageFromAssetsCar(cfBundleIconName string, resPath string) (img image.Image, err error) {
	b, err := ioutil.ReadFile(filepath.Join(resPath, "Assets.car"))
	if err != nil {
		return nil, err
	}

	a, err := asset.NewWithReadSeeker(bytes.NewReader(b))
	if err != nil {
		return nil, err
	}

	return a.Image(cfBundleIconName)
}
