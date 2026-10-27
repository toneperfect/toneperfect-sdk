// Usage: TONEPERFECT_API_KEY=tp_live_... go run ./examples/assess-file hello.wav "你好" zh-CN
package main

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/vm542/toneperfect-sdk/go"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: assess-file AUDIO TEXT [LANGUAGE]")
		os.Exit(2)
	}
	language := "zh-CN"
	if len(os.Args) > 3 {
		language = os.Args[3]
	}
	client := toneperfect.New("")
	res, err := client.AssessFile(context.Background(), os.Args[1], toneperfect.AssessParams{Text: os.Args[2], Language: language})
	var apiErr *toneperfect.Error
	switch {
	case errors.Is(err, toneperfect.ErrPaymentRequired):
		fmt.Fprintln(os.Stderr, err, "— see https://api.toneperfect.app/dashboard")
		os.Exit(1)
	case errors.As(err, &apiErr):
		fmt.Fprintf(os.Stderr, "%v (retry with the same key: %v)\n", err, apiErr.Retryable())
		os.Exit(1)
	case err != nil:
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if !res.Assessable() {
		fmt.Printf("not assessable: %s (no credits charged)\n", res.Reason())
		return
	}
	fmt.Printf("overall %.1f\n", *res.Overall())
	for _, w := range res.Words() {
		fmt.Printf("  %v: %v\n", w["word"], w["score"])
	}
	fmt.Println("billing", res.Billing())
}
