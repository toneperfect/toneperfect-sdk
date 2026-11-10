// Assess one recording and print what the API returned.
//
//	export TONEPERFECT_API_KEY=tp_test_...      (or tp_live_... for real scores)
//	go run ./examples/assess-file hello.ogg 你好 zh-CN
package main

import (
	"context"
	"errors"
	"fmt"
	"os"

	toneperfect "github.com/vm542/toneperfect-sdk/go"
)

func main() {
	if len(os.Args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: assess-file <audio> <text> <locale>")
		os.Exit(2)
	}
	client := toneperfect.New("") // reads TONEPERFECT_API_KEY
	res, err := client.AssessFile(context.Background(), os.Args[1], toneperfect.AssessParams{Text: os.Args[2], Language: os.Args[3]})
	var apiErr *toneperfect.Error
	switch {
	case errors.Is(err, toneperfect.ErrPaymentRequired) && errors.As(err, &apiErr):
		fmt.Fprintf(os.Stderr, "%s: %s Fix it at %s\n", apiErr.Code, apiErr.Message, apiErr.BillingURL)
		os.Exit(1)
	case err != nil:
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("model:", res.ModelVersion, "| request:", res.ID, "| engine:", res.Engine(), "| test:", res.Test)
	fmt.Println("billing:", res.Billing.Credits, "credit(s), source", res.Billing.Source)
	if !res.Assessable {
		fmt.Println("not assessable:", res.Reason)
		os.Exit(1)
	}
	for _, w := range res.Words {
		for _, p := range w.Phones {
			if p.Decision == "review" {
				fmt.Printf("%s: %s expected %v, heard %v\n", w.Word, p.Dimension, p.Expected, p.Heard)
			}
		}
	}
}
