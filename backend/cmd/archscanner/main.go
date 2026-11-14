package main

import (
	"fmt"
	"os"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "archscanner: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	// Wire omcrgnt app + srv-http + scheduler + domain next.
	fmt.Println("archscanner backend: stub")
	return nil
}
