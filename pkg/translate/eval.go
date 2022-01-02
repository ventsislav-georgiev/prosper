package translate

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
)

func Eval(expr string) (s string, icon []byte, onEnter func(), err error) {
	parts := strings.Split(strings.ToLower(expr), " ")
	if len(parts) != 3 {
		return "", nil, nil, helpers.ErrSkip
	}

	if parts[1] != "in" && parts[1] != "to" {
		return "", nil, nil, helpers.ErrSkip
	}

	_, ok := code[parts[2]]
	if !ok {
		return "", nil, nil, helpers.ErrSkip
	}

	resp, err := http.DefaultClient.Get(fmt.Sprintf("https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=%s&dt=t&q=%s", parts[2], url.QueryEscape(parts[0])))
	if err != nil {
		return err.Error(), nil, nil, nil
	}

	defer resp.Body.Close()

	var result []interface{}
	err = json.NewDecoder(resp.Body).Decode(&result)
	if err != nil {
		return err.Error(), nil, nil, nil
	}

	if len(result) == 0 {
		return "N/A", nil, nil, nil
	}

	attempts, ok := result[0].([]interface{})
	if !ok {
		return "N/A", nil, nil, nil
	}

	var text string
	for _, slice := range attempts {
		translations, ok := slice.([]interface{})
		if !ok {
			return "N/A", nil, nil, nil
		}

		for _, translatedText := range translations {
			if translatedText != nil {
				text = fmt.Sprintf("%s", translatedText)
				break
			}
		}
	}

	return strings.ToLower(text), nil, nil, nil
}
