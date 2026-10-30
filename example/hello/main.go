// Command hello is a minimal Substrate actor: an HTTP server on port 80 that
// says hello and counts the requests it has served. The count lives in
// memory, so it survives a suspend and resume under memory-fidelity
// snapshots.
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"sync/atomic"
)

func main() {
	var requests atomic.Uint64
	host, _ := os.Hostname()

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		n := requests.Add(1)
		fmt.Fprintf(w, "Hello, world from %s! (request %d)\n", host, n)
	})
	// The ActorTemplate's wakeupProbe polls this.
	http.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	log.Print("hello: listening on :80")
	log.Fatal(http.ListenAndServe(":80", nil))
}
