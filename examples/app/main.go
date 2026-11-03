// Example service for app-release.yml. It does just enough to exercise the
// pipeline: it serves HTTP, exports OpenTelemetry HTTP server metrics with
// service.name and service.version (from OTEL_SERVICE_NAME and
// OTEL_RESOURCE_ATTRIBUTES, which the deploy template sets), and lets the
// self-test inject failures to prove the canary analysis stops a bad release.
package main

import (
	"context"
	"errors"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Export only when a collector is configured, so the binary runs anywhere.
	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") != "" {
		shutdown, err := setupMetrics(ctx)
		if err != nil {
			log.Fatalf("metrics: %v", err)
		}
		defer shutdown(context.Background())
	}

	// FAIL_RATIO (0..1) makes that share of /work requests return 500. Used only
	// by the self-test's degraded release; unset in normal releases.
	failRatio, _ := strconv.ParseFloat(os.Getenv("FAIL_RATIO"), 64)

	app := http.NewServeMux()
	app.HandleFunc("GET /work", func(w http.ResponseWriter, r *http.Request) {
		if failRatio > 0 && rand.Float64() < failRatio {
			http.Error(w, "injected failure", http.StatusInternalServerError)
			return
		}
		_, _ = w.Write([]byte("ok\n"))
	})

	mux := http.NewServeMux()
	// Probes stay outside the instrumented handler so they never count toward analysis.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.Handle("/", otelhttp.NewHandler(app, "http.server"))

	srv := &http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("serve: %v", err)
		}
	}()
	log.Printf("listening on :8080")
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}

func setupMetrics(ctx context.Context) (func(context.Context) error, error) {
	exporter, err := otlpmetricgrpc.New(ctx, otlpmetricgrpc.WithInsecure())
	if err != nil {
		return nil, err
	}
	res, err := resource.New(ctx, resource.WithFromEnv(), resource.WithTelemetrySDK())
	if err != nil {
		return nil, err
	}
	provider := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exporter, sdkmetric.WithInterval(5*time.Second))),
	)
	otel.SetMeterProvider(provider)
	return provider.Shutdown, nil
}
