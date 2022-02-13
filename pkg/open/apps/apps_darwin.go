package apps

import (
	"bufio"
	"bytes"
	"image"
	"image/png"
	"io"
	"io/fs"
	"io/ioutil"
	"os"
	"path/filepath"
	"strings"

	"github.com/groob/plist"
	"github.com/iineva/bom/pkg/asset"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers/exec"
	"yrh.dev/icns"
)

const (
	globalAppsPath = "/Applications"
	sysAppsPath    = "/System/Applications"
)

var (
	homeDir      string
	userAppsPath string
)

func init() {
	homeDir, _ = os.UserHomeDir()
	if homeDir != "" {
		userAppsPath = filepath.Join(homeDir, "Applications")
	}
}

func Find() FuzzySource {
	apps := findRecursive(globalAppsPath, 0)
	apps = append(apps, findRecursive(sysAppsPath, 0)...)
	if userAppsPath != "" {
		apps = append(apps, findRecursive(userAppsPath, 0)...)
	}
	return apps
}

func findRecursive(dir string, level int) FuzzySource {
	apps := make(FuzzySource, 0)

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
	infoPlistPath := findInfoPList(appPath)

	if infoPlistPath == "" {
		return nil, nil
	}

	info, err := ioutil.ReadFile(filepath.Join(infoPlistPath, "Info.plist"))
	if err != nil {
		return nil, nil
	}

	var bundleHeader struct {
		CFBundleIconFile string                 `plist:"CFBundleIconFile"`
		CFBundleIconName string                 `plist:"CFBundleIconName"`
		CFBundleIcons    map[string]interface{} `plist:"CFBundleIcons"`
	}

	err = plist.Unmarshal(info, &bundleHeader)
	if err != nil {
		return nil, err
	}

	if bundleHeader.CFBundleIconFile == "" && bundleHeader.CFBundleIconName == "" && bundleHeader.CFBundleIcons == nil {
		return nil, nil
	}

	var img image.Image
	resPath := filepath.Join(infoPlistPath, "Resources")
	if _, err := os.Stat(resPath); err != nil {
		resPath = infoPlistPath
	}

	if bundleHeader.CFBundleIconFile != "" {
		if filepath.Ext(bundleHeader.CFBundleIconFile) == "" {
			bundleHeader.CFBundleIconFile += ".icns"
		}
		img, err = getIconFromIcns(bundleHeader.CFBundleIconFile, resPath)
	}

	if img == nil && bundleHeader.CFBundleIconName != "" {
		img, err = getIconFromAssetsCar(bundleHeader.CFBundleIconName, resPath)
	}

	if img == nil && bundleHeader.CFBundleIcons != nil {
		if primaryIcon, ok := bundleHeader.CFBundleIcons["CFBundlePrimaryIcon"]; ok {
			if primaryIconData, ok := primaryIcon.(map[string]interface{}); ok {
				if nameData, ok := primaryIconData["CFBundleIconName"]; ok {
					if name, ok := nameData.(string); ok {
						img, err = getIconFromFile(resPath, name)
					}
				}
			}
		}
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

func findInfoPList(root string) string {
	if _, err := os.Stat(filepath.Join(root, "Info.plist")); err == nil {
		return root
	}

	var infoPath string
	filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}

		if d.IsDir() {
			if _, err := os.Stat(filepath.Join(path, "Info.plist")); err == nil {
				infoPath = path
				return io.EOF
			}
		}

		return nil
	})

	return infoPath
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

func getIconFromFile(path string, name string) (img image.Image, err error) {
	var imgFile *os.File
	entries, err := os.ReadDir(path)

	for i := len(entries) - 1; i > 0; i-- {
		e := entries[i]
		if e.IsDir() || !strings.HasPrefix(e.Name(), name) {
			continue
		}

		imgFile, err = os.Open(filepath.Join(path, e.Name()))
		if err != nil {
			continue
		}

		defer imgFile.Close()

		img, _, err = image.Decode(bufio.NewReader(imgFile))
		if err == nil {
			return
		}
	}

	return
}
