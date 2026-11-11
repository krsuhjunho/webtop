package main

import (
	"log"
	"net"
	"os"

	"github.com/maxmind/mmdbwriter"
	"github.com/maxmind/mmdbwriter/mmdbtype"
)

func insert(w *mmdbwriter.Tree, cidr, country string) {
	_, n, err := net.ParseCIDR(cidr)
	if err != nil {
		log.Fatal(err)
	}
	rec := mmdbtype.Map{
		"country": mmdbtype.Map{
			"iso_code": mmdbtype.String(country),
			"names":    mmdbtype.Map{"en": mmdbtype.String(country)},
		},
	}
	if err := w.Insert(n, rec); err != nil {
		log.Fatal(err)
	}
}

func main() {
	w, err := mmdbwriter.New(mmdbwriter.Options{
		DatabaseType:            "GeoLite2-Country",
		RecordSize:              24,
		Languages:               []string{"en"},
		IncludeReservedNetworks: true,
	})
	if err != nil {
		log.Fatal(err)
	}
	insert(w, "203.0.113.0/24", "US")
	insert(w, "192.0.2.0/24", "KR")
	insert(w, "198.51.100.0/24", "JP")
	insert(w, "175.139.0.0/16", "MY")
	fh, err := os.Create(os.Args[1])
	if err != nil {
		log.Fatal(err)
	}
	defer fh.Close()
	if _, err := w.WriteTo(fh); err != nil {
		log.Fatal(err)
	}
}
