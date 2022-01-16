package apps

import (
	"bufio"
	"bytes"
	"image"
	"image/png"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"github.com/srwiley/oksvg"
	"github.com/srwiley/rasterx"
	open "github.com/ventsislav-georgiev/prosper/pkg/helpers/exec"
)

const (
	sysAppsPath  = "/usr/share/applications/"
	sysAppsPath2 = "/usr/local/share/applications/"
)

var (
	userAppsPath string
	iconPathsMap = &sync.Map{}
)

func init() {
	homeDir, _ := os.UserHomeDir()
	if homeDir != "" {
		userAppsPath = filepath.Join(homeDir, ".local/share/applications/")
	}

	go func() {
		themes := make([]string, 0, 4)
		out, err := exec.Command("gsettings", "get", "org.gnome.desktop.interface", "gtk-theme").Output()
		if err == nil {
			themes = append(themes, strings.Trim(string(out), "'\n "))
		}
		out, err = exec.Command("gsettings", "get", "org.gnome.desktop.interface", "icon-theme").Output()
		if err == nil {
			themes = append(themes, strings.Trim(string(out), "'\n "))
		}
		themes = append(themes, "hicolor", "HighContrast")

		paths := make([]string, 0, 5)
		if homeDir != "" {
			paths = append(paths, filepath.Join(homeDir, ".icons"))
		}
		datadirs := os.Getenv("XDG_DATA_DIRS")
		for _, p := range filepath.SplitList(datadirs) {
			paths = append(paths, filepath.Join(p, "icons"))
		}

		sizes := []string{"scalable", "256x256", "256", "128x128", "128", "64x64", "64", "48x48", "48", "32x32", "32", "24x24", "24", "22x22", "22", "16x16", "16"}
		desiredSizes := make([]string, 0, len(sizes)*2)
		for _, s := range sizes {
			desiredSizes = append(desiredSizes, s+"@2x", s)
		}

		iconPaths := make([]string, 0, len(paths)*10)
		for _, p := range paths {
			for _, t := range themes {
				path := filepath.Join(p, t)
				files, err := ioutil.ReadDir(path)
				if err != nil {
					continue
				}

				dirs := make([]string, len(desiredSizes)+len(files))
				dirs = append(dirs, desiredSizes...)
				for _, f := range files {
					if f.IsDir() {
						dirs = append(dirs, f.Name())
					}
				}

				for _, d := range dirs {
					path = filepath.Join(p, t, d)
					files, err := ioutil.ReadDir(path)
					if err != nil {
						continue
					}

					dirs = make([]string, len(desiredSizes)+len(files))
					dirs = append(dirs, desiredSizes...)
					for _, f := range files {
						if f.IsDir() {
							dirs = append(dirs, f.Name())
						}
					}

					for _, d := range dirs {
						iconPaths = append(iconPaths, filepath.Join(path, d))
					}
				}
			}
		}
		iconPaths = append(iconPaths, "/usr/share/pixmaps")
		iconPathsMap.Store("val", iconPaths)
	}()
}

func Find() FuzzySource {
	apps := findRecursive(sysAppsPath, 0)
	apps = append(apps, findRecursive(sysAppsPath2, 0)...)
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
		if filepath.Ext(f.Name()) == ".desktop" {
			e := open.Info{
				Path:     dir,
				Filename: f.Name(),
			}
			resolveDisplayName(&e)
			if e.DisplayName == "" {
				e.DisplayName = f.Name()
			}
			apps = append(apps, e)
		} else if level < 1 && f.IsDir() {
			apps = append(apps, findRecursive(filepath.Join(dir, f.Name()), level+1)...)
		}
	}

	return apps
}

func resolveDisplayName(e *open.Info) {
	file, err := os.Open(e.Filepath())
	if err != nil {
		return
	}

	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		text := scanner.Text()
		if e.DisplayName == "" && strings.HasPrefix(text, "Name=") {
			e.DisplayName = text[5:]
		}
		if e.IconName == "" && strings.HasPrefix(text, "Icon=") {
			e.IconName = text[5:]
		}
		if e.DisplayName != "" && e.IconName != "" {
			return
		}
	}
}

func ExtractIcon(app open.Info) ([]byte, error) {
	v, ok := iconPathsMap.Load("val")
	if !ok {
		return nil, nil
	}
	iconPaths, ok := v.([]string)
	if !ok {
		return nil, nil
	}

	name := app.IconName
	if name == "" {
		name = app.Filename[:len(app.Filename)-8]
	}

	icon, path, err := extractIcon(iconPaths, name, ".png")
	if err == nil {
		return icon, nil
	}

	icon, path, err = extractIcon(iconPaths, name, ".svg")
	if err == nil {
		return svgToPng(path)
	}

	return nil, err
}

func extractIcon(iconPaths []string, name string, ext string) (icon []byte, path string, err error) {
	for _, p := range iconPaths {
		if filepath.Ext(name) == ext {
			path = filepath.Join(p, name)
		} else {
			path = filepath.Join(p, name+ext)
		}

		_, err = os.Stat(path)
		if err != nil {
			continue
		}

		if ext == ".svg" {
			return
		}

		icon, err = os.ReadFile(path)
		if err == nil {
			return
		}
	}
	return
}

func svgToPng(svg string) ([]byte, error) {
	w, h := 256, 256
	icon, err := oksvg.ReadIcon(svg)
	if err != nil {
		return nil, err
	}

	icon.SetTarget(0, 0, float64(w), float64(h))
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	icon.Draw(rasterx.NewDasher(w, h, rasterx.NewScannerGV(w, h, img, img.Bounds())), 1)

	var buf bytes.Buffer
	err = png.Encode(&buf, img)
	if err != nil {
		return nil, err
	}

	return buf.Bytes(), nil
}
