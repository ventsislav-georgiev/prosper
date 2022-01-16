package apps

import (
	"bytes"
	"fmt"
	"image"
	"image/png"
	"io/ioutil"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	lnk "github.com/parsiya/golnk"
	"github.com/tc-hib/winres"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/open/exec"
)

var (
	globalAppsPath  string
	userAppsPath    string
	userAppsPath2   string
	envExpandRegexp = regexp.MustCompile(`%(.*?)%`)
)

const (
	envExpandRegexpReplace = "${$1}"
)

func init() {
	homeDir, _ := os.UserHomeDir()
	if homeDir != "" && helpers.IsWindows {
		globalAppsPath = filepath.Join(homeDir[:3], "ProgramData\\Microsoft\\Windows\\Start Menu\\Programs")
		userAppsPath = filepath.Join(homeDir, "AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs")
		userAppsPath2 = filepath.Join(homeDir, "AppData\\Roaming\\Microsoft\\Internet Explorer\\Quick Launch\\User Pinned\\TaskBar")
	}
}

func Find() FuzzySource {
	apps := findRecursive(globalAppsPath, 0)
	if userAppsPath != "" {
		apps = append(apps, findRecursive(userAppsPath, 0)...)
	}
	if userAppsPath2 != "" {
		apps = append(apps, findRecursive(userAppsPath2, 0)...)
	}

	return apps
}

func findRecursive(dir string, level int) FuzzySource {
	apps := make(FuzzySource, 0)

	if !helpers.IsWindows {
		return apps
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return apps
	}

	for _, f := range entries {
		if filepath.Ext(f.Name()) == ".lnk" {
			apps = append(apps, exec.Info{
				DisplayName: f.Name()[:len(f.Name())-4],
				Path:        dir,
				Filename:    f.Name(),
			})
		} else if level < 5 && f.IsDir() {
			apps = append(apps, findRecursive(filepath.Join(dir, f.Name()), level+1)...)
		}
	}

	return apps
}

func ExtractIcon(app exec.Info) (icon []byte, err error) {
	f, lnkErr := lnk.File(app.Filepath())
	if lnkErr != nil {
		fmt.Println(lnkErr)
	}

	path := f.StringData.IconLocation
	if path == "" {
		path = f.LinkInfo.LocalBasePath
	}
	if path == "" {
		path = f.LinkInfo.LocalBasePathUnicode
	}
	if path == "" {
		path = f.LinkInfo.LocalBasePathUnicode
	}
	if path == "" {
		path = strings.TrimPrefix(strings.Split(f.StringData.NameString, ",")[0], "@")
	}
	if path == "" {
		fmt.Println("no path: ", app.Filepath())
		return nil, nil
	}

	path = strings.ToLower(os.ExpandEnv(envExpandRegexp.ReplaceAllString(path, envExpandRegexpReplace)))
	ext := filepath.Ext(path)

	if ext == ".dll" && strings.Contains(path, "system32") {
		sysres := strings.Replace(path, "system32", "systemresources", 1) + ".mun"
		if _, err := os.Stat(sysres); err == nil {
			path = sysres
		}
	}

	switch ext {
	case ".exe", ".dll":
		icon, err = extractIconFromResFile(path, int(f.Header.IconIndex))
	case ".ico":
		icon, err = extractIconFromIco(path)
	}

	if icon == nil {
		fmt.Println(path)
	}

	return
}

func extractIconFromResFile(path string, idx int) (icon []byte, err error) {
	data, err := ioutil.ReadFile(path)
	if err != nil {
		return nil, err
	}

	rs, err := winres.LoadFromEXE(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}

	te := rs.Types[winres.RT_GROUP_ICON]
	if te == nil {
		return nil, nil
	}

	var img []byte
	if idx < 0 {
		resID := winres.ID(math.Abs(float64(idx)))
		img = getIconFromResourceSet(rs, resID)
		if img != nil {
			return img, nil
		}
	}

	te.Order()
	for _, resID := range te.OrderedKeys {
		img = getIconFromResourceSet(rs, resID)
		if img != nil {
			break
		}
	}

	return img, nil
}

func extractIconFromIco(path string) (icon []byte, err error) {
	data, err := ioutil.ReadFile(path)
	if err != nil {
		return nil, err
	}

	ico, err := winres.LoadICO(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}

	var img []byte
	for _, i := range ico.Images {
		if len(img) < len(i.Image) {
			img = i.Image
		}
	}

	return img, nil
}

func getIconFromResourceSet(rs *winres.ResourceSet, resID winres.Identifier) (img []byte) {
	ico, err := rs.GetIcon(resID)
	if err != nil {
		return
	}

	for _, i := range ico.Images {
		data, err := extractIconToPNG(i.Image)
		if err == nil && len(img) < len(data) {
			img = data
		}
	}
	return
}

func extractIconToPNG(imgBytes []byte) ([]byte, error) {
	img, _, err := image.Decode(bytes.NewReader(imgBytes))
	if err != nil {
		return nil, err
	}

	var buf bytes.Buffer
	err = png.Encode(&buf, img)
	if err != nil {
		return nil, err
	}

	return buf.Bytes(), nil
}
