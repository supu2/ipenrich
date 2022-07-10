package main

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"

	"github.com/gorilla/handlers"
	"github.com/oschwald/geoip2-golang"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var ok bool
var asn, city, port string
var err error
var asndb, citydb *geoip2.Reader

type enrich struct {
	Country, City, AutonomousSystemOrganization string
	AutonomousSystemNumber                      uint
	Latitude, Longitude                         float64
}

// ip enrichment counter
var ipEnrichCounter = prometheus.NewCounter(
	prometheus.CounterOpts{
		Name: "ipenrich_request_count",
		Help: "Number of request handled by enricher handler",
	},
)

// ip enrichment latency
var ipEnrichLatency = prometheus.NewSummary(
	prometheus.SummaryOpts{
		Name:       "ipenrich_request_durations",
		Help:       "Ipenrich requests latencies in seconds",
		Objectives: map[float64]float64{0.5: 0.05, 0.9: 0.01, 0.99: 0.001},
	})

// load env variable and  maxmind db
func init() {

	prometheus.MustRegister(ipEnrichCounter, ipEnrichLatency)
	// Get maxminddb path value from env
	path, ok := os.LookupEnv("MAXMIND_DB")
	if ok {
		asn = path + "GeoLite2-ASN.mmdb"
		city = path + "GeoLite2-City.mmdb"
	} else {
		asn = "/opt/GeoLite2-ASN.mmdb"
		city = "/opt/GeoLite2-City.mmdb"
	}

	// Get port value from env
	port, ok = os.LookupEnv("PORT")

	if !ok {
		port = ":8000"
	} else {
		port = ":" + port
	}
	// load maxmind asndb
	asndb, err = geoip2.Open(asn)
	if err != nil {
		log.Fatal(err)
		defer asndb.Close()
	}
	// load maxmind citydb
	citydb, err = geoip2.Open(city)
	if err != nil {
		log.Fatal(err)
		defer citydb.Close()
	}
}

func enricher(w http.ResponseWriter, r *http.Request) {
	timer := prometheus.NewTimer(prometheus.ObserverFunc(func(v float64) {
		us := v * 1000000 // make microseconds
		ipEnrichLatency.Observe(us)
	}))
	defer timer.ObserveDuration()
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
	asn_r, err := asndb.ASN(ip)
	city_r, err := citydb.City(ip)
	result := enrich{
		City:                         city_r.City.Names["en"],
		Country:                      city_r.Country.Names["en"],
		Latitude:                     city_r.Location.Latitude,
		Longitude:                    city_r.Location.Longitude,
		AutonomousSystemNumber:       asn_r.AutonomousSystemNumber,
		AutonomousSystemOrganization: asn_r.AutonomousSystemOrganization,
	}
	if err != nil {
		log.Fatal(err)
	}
	ipEnrichCounter.Inc()
	response, _ := json.Marshal(result)
	w.Write(response)

}

//TODO, create log layer
func main() {
	// TODO, auto update maxmind file
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.Handle("/", handlers.LoggingHandler(os.Stdout, http.HandlerFunc(enricher)))
	log.Fatal((http.ListenAndServe(port, mux)))
}
