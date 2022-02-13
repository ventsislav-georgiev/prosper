package numi

import (
	"io"
	"net/http"
	"net/url"

	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/open"
	"github.com/ventsislav-georgiev/prosper/pkg/open/apps"
)

var numiIcon []byte

func Eval(expr string) (s string, icon []byte, onEnter func(), err error) {
	if !helpers.IsDarwin {
		return "", nil, nil, helpers.ErrSkip
	}

	resp, err := http.DefaultClient.Get("http://localhost:15055?q=" + url.PathEscape(expr) + " ")
	if err != nil {
		return "", nil, nil, helpers.ErrSkip
	}

	if numiIcon == nil {
		numi, err := open.FindApp("Numi")
		if err == nil {
			i, _ := apps.ExtractIcon(numi)
			numiIcon = i
		}
	}

	defer resp.Body.Close()
	o, err := io.ReadAll(resp.Body)

	if string(o) == "" {
		return "", nil, nil, helpers.ErrSkip
	}

	return string(o), numiIcon, nil, nil
}
