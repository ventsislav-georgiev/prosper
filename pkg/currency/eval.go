package currency

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
)

func Eval(expr string) (s string, icon []byte, onEnter func(), err error) {
	parts := strings.Split(strings.ToLower(expr), " ")
	if len(parts) != 4 {
		return "", nil, nil, helpers.ErrSkip
	}

	_, ok := curr[parts[1]]
	if !ok {
		return "", nil, nil, helpers.ErrSkip
	}

	if parts[2] != "in" && parts[2] != "to" {
		return "", nil, nil, helpers.ErrSkip
	}

	symbol, ok := curr[parts[3]]
	if !ok {
		return "", nil, nil, helpers.ErrSkip
	}

	_, err = strconv.ParseFloat(parts[0], 64)
	if err != nil {
		return "", nil, nil, helpers.ErrSkip
	}

	resp, err := http.DefaultClient.Get(fmt.Sprintf("https://api.exchangerate.host/convert?from=%s&to=%s&amount=%s", parts[1], parts[3], parts[0]))
	if err != nil {
		return err.Error(), nil, nil, nil
	}

	defer resp.Body.Close()

	var r struct {
		Result float64 `json:"result"`
	}
	err = json.NewDecoder(resp.Body).Decode(&r)
	if err != nil {
		return err.Error(), nil, nil, nil
	}

	return fmt.Sprintf("%.2f %s", r.Result, symbol), nil, nil, nil
}
