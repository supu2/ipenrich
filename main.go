package main

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"

	"github.com/oschwald/geoip2-golang"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var ok bool
var mmdb, port string
var err error
var db *geoip2.Reader

//TODO, Measure response time for ensure the service reliability
// ip enrichment counter
var ipenrichrequestCounter = prometheus.NewCounter(
	prometheus.CounterOpts{
		Name: "ipenrich_request_count",
		Help: "Number of request handled by enricher handler",
	},
)

// load env variable and  maxmind db
func init() {
	// Get maxminddb path value from env
	if mmdb, ok = os.LookupEnv("MAXMIND_DB"); !ok {
		mmdb = "/opt/GeoLite2-ASN.mmdb"
	}

	// Get port value from env
	port, ok = os.LookupEnv("PORT")

	if !ok {
		port = ":8000"
	} else {
		port = ":" + port
	}
	// load maxmind db
	db, err = geoip2.Open(mmdb)
	if err != nil {
		log.Fatal(err)
		defer db.Close()
	}

}

func enricher(w http.ResponseWriter, r *http.Request) {
	// set Content type json
	w.Header().Set("Content-Type", "application/json")

	// get ip params from url
	parm := r.URL.Query().Get("ip")
	if parm == "" {
		w.Write([]byte(`{"usage": "/?ip=8.8.8.8"}`))
		return
	}
	ip := net.ParseIP(parm)
	if ip == nil {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error": "ip address is not valid"}`))
		return
	}

	// lookup ip param to maxmind db
	record, err := db.ASN(ip)
	jsonString, _ := json.Marshal(record)

	if err != nil {
		log.Fatal(err)
	}
	ipenrichrequestCounter.Inc()
	w.Write(jsonString)

}

//TODO, create log layer
func main() {
	// TODO, auto update maxmind file
	prometheus.MustRegister(ipenrichrequestCounter)
	http.Handle("/metrics", promhttp.Handler())
	http.HandleFunc("/", enricher)
	log.Fatal(http.ListenAndServe(port, nil))
}