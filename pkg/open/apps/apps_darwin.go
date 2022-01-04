package apps

import (
	"bytes"
	"image"
	"image/png"
	"io/ioutil"
	"os"
	"path/filepath"

	"github.com/groob/plist"
	"github.com/iineva/bom/pkg/asset"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/open/exec"
	"yrh.dev/icns"
)

func init() {
	homeDir, _ := os.UserHomeDir()
	if homeDir != "" && helpers.IsDarwin {
		darwinUserAppsPath = filepath.Join(homeDir, "Applications")
	}
}

const (
	darwinGlobalAppsPath = "/Applications"
	darwinSysAppsPath    = "/System/Applications"
)

var (
	darwinUserAppsPath string
)

func Find() FuzzySource {
	apps := findRecursive(darwinGlobalAppsPath, 0)
	apps = append(apps, findRecursive(darwinSysAppsPath, 0)...)
	if darwinUserAppsPath != "" {
		apps = append(apps, findRecursive(darwinUserAppsPath, 0)...)
	}
	return apps
}

func findRecursive(dir string, level int) FuzzySource {
	apps := make(FuzzySource, 0)

	if !helpers.IsDarwin {
		return apps
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return apps
	}

	for _, f := range entries {
		if filepath.Ext(f.Name()) == ".app" {
			apps = append(apps, exec.Info{
				DisplayName: f.Name()[:len(f.Name())-4],
				Path:        dir,
				Filename:    f.Name(),
			})
		} else if level < 1 && f.IsDir() {
			apps = append(apps, findRecursive(filepath.Join(dir, f.Name()), level+1)...)
		}
	}

	return apps
}

func ExtractIcon(app exec.Info) (icon []byte, err error) {
	appPath := filepath.Join(app.Path, app.Filename)

	info, err := ioutil.ReadFile(filepath.Join(appPath, "Contents", "Info.plist"))
	if err != nil {
		return nil, nil
	}

	var bundleHeader struct {
		CFBundleIconFile string `plist:"CFBundleIconFile"`
		CFBundleIconName string `plist:"CFBundleIconName"`
	}

	err = plist.Unmarshal(info, &bundleHeader)
	if err != nil {
		return nil, err
	}

	if bundleHeader.CFBundleIconFile == "" && bundleHeader.CFBundleIconName == "" {
		return nil, nil
	}

	var img image.Image
	resPath := filepath.Join(app.Path, app.Filename, "Contents", "Resources")

	if bundleHeader.CFBundleIconFile != "" {
		if filepath.Ext(bundleHeader.CFBundleIconFile) == "" {
			bundleHeader.CFBundleIconFile += ".icns"
		}
		img, err = getIconFromIcns(bundleHeader.CFBundleIconFile, resPath)
	}

	if img == nil && bundleHeader.CFBundleIconName != "" {
		img, err = getIconFromAssetsCar(bundleHeader.CFBundleIconName, resPath)
	}

	if err != nil || img == nil {
		return nil, err
	}

	var buf bytes.Buffer
	err = png.Encode(&buf, img)
	if err != nil {
		return nil, err
	}

	return buf.Bytes(), nil
}

func getIconFromIcns(cfBundleIconFile string, resPath string) (img image.Image, err error) {
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

func getIconFromAssetsCar(cfBundleIconName string, resPath string) (img image.Image, err error) {
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
