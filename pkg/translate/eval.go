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
	isDigit := expr[0] >= 48 && expr[0] <= 57
	if isDigit || expr[0] != '(' {
		return "", nil, nil, helpers.ErrSkip
	}

	parts := strings.Split(strings.ToLower(expr), " ")
	if len(parts) < 3 {
		return "", nil, nil, helpers.ErrSkip
	}

	lastTwo := parts[len(parts)-2:]

	if lastTwo[0] != "in" && lastTwo[0] != "to" {
		return "", nil, nil, helpers.ErrSkip
	}

	_, ok := code[lastTwo[1]]
	if !ok {
		return "", nil, nil, helpers.ErrSkip
	}

	sentence := strings.Join(parts[:len(parts)-2], " ")
	resp, err := http.DefaultClient.Get(fmt.Sprintf("https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=%s&dt=t&q=%s", lastTwo[1], url.QueryEscape(sentence)))
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
