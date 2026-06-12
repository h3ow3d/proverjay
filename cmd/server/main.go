package main

import (
	"log"
	"net/http"
)

func main() {
	log.Println("listening on :8080")
	if err := http.ListenAndServe(":8080", newServer()); err != nil {
		log.Fatal(err)
	}
}
