package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/gorilla/handlers"
	"github.com/oschwald/geoip2-golang"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var asn, city, port string
var asndb, citydb *geoip2.Reader
var usage = "ipenrich [args] \n -s \t random sleep"
var sleep = false

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
	argsWithProg := os.Args
	if len(argsWithProg) > 2 {
		log.Fatalln(usage)
	} else if len(argsWithProg) == 2 {
		sleep = true
	}

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
	port, ok := os.LookupEnv("PORT")

	if !ok {
		port = ":8000"
	} else {
		port = ":" + port
	}
	// load maxmind asndb
	asndb, err := geoip2.Open(asn)
	if err != nil {
		log.Fatal(err)
		defer func() {
			_ = asndb.Close()
		}()
	}
	// load maxmind citydb
	citydb, err := geoip2.Open(city)
	if err != nil {
		log.Fatal(err)
		defer func() {
			_ = citydb.Close()
		}()
	}
}

func enricher(w http.ResponseWriter, r *http.Request) {
	timer := prometheus.NewTimer(prometheus.ObserverFunc(func(v float64) {
		ipEnrichLatency.Observe(v)
	}))
	defer timer.ObserveDuration()
	// set Content type json
	w.Header().Set("Content-Type", "application/json")

	// get ip params from url
	parm := r.URL.Query().Get("ip")
	if parm == "" {
		_, err := w.Write([]byte(`{"usage": "/?ip=8.8.8.8"}`))
		if err != nil {
			fmt.Println(err)
		}
		return
	}
	ip := net.ParseIP(parm)
	if ip == nil {
		w.WriteHeader(http.StatusBadRequest)
		_, err := w.Write([]byte(`{"error": "ip address is not valid"}`))
		if err != nil {
			fmt.Println(err)
		}
		return
	}
	///rand sleep for test alert system
	if sleep {
		rand.Seed(time.Now().UnixNano())
		n := rand.Intn(1000) // n will be between 0 and 1000
		fmt.Printf("Sleeping %d milliseconds...\n", n)
		time.Sleep(time.Duration(n) * time.Millisecond)
	}

	// lookup ip param to maxmind db
	asn_r, err := asndb.ASN(ip)
	if err != nil {
		log.Fatal(err)
	}
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
	_, err = w.Write(response)
	if err != nil {
		fmt.Println(err)
	}

}

//TODO, create log layer
func main() {
	// TODO, auto update maxmind file
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.Handle("/", handlers.LoggingHandler(os.Stdout, http.HandlerFunc(enricher)))
	log.Fatal((http.ListenAndServe(port, mux)))
}
