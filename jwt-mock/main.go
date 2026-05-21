package main

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"os"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var (
	privateKey *rsa.PrivateKey
	issuerURL  string
)

type TokenRequest struct {
	Sub        string `json:"sub"`
	Aud        string `json:"aud"`
	ExpMinutes int    `json:"exp_minutes"`
}

type TokenResponse struct {
	AccessToken string `json:"access_token"`
	ExpiresIn   int    `json:"expires_in"`
	TokenType   string `json:"token_type"`
}

// jwk is a minimal JSON Web Key for an RSA public key.
type jwk struct {
	Kty string `json:"kty"`
	Use string `json:"use"`
	Alg string `json:"alg"`
	Kid string `json:"kid"`
	N   string `json:"n"`
	E   string `json:"e"`
}

func main() {
	issuerURL = os.Getenv("ISSUER_URL")
	if issuerURL == "" {
		issuerURL = "http://localhost:8080"
	}
	listenAddr := os.Getenv("LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = ":8080"
	}

	var err error
	log.Println("Generating RSA-4096 key pair...")
	privateKey, err = rsa.GenerateKey(rand.Reader, 4096)
	if err != nil {
		log.Fatalf("failed to generate RSA key: %v", err)
	}
	log.Println("Key pair generated.")

	http.HandleFunc("/.well-known/jwks.json", handleJWKS)
	http.HandleFunc("/token", handleToken)
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	log.Printf("JWT mock listening on %s (issuer: %s)", listenAddr, issuerURL)
	if err := http.ListenAndServe(listenAddr, nil); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func handleJWKS(w http.ResponseWriter, r *http.Request) {
	pub := &privateKey.PublicKey

	key := jwk{
		Kty: "RSA",
		Use: "sig",
		Alg: "RS512",
		Kid: "demo-key-1",
		N:   base64.RawURLEncoding.EncodeToString(pub.N.Bytes()),
		E:   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes()),
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string][]jwk{"keys": {key}})
}

func handleToken(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req TokenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, fmt.Sprintf("invalid request: %v", err), http.StatusBadRequest)
		return
	}

	if req.Sub == "" {
		req.Sub = "demo-user"
	}
	if req.Aud == "" {
		req.Aud = "api.demo.local"
	}
	if req.ExpMinutes == 0 {
		req.ExpMinutes = 60
	}

	now := time.Now()
	expiry := now.Add(time.Duration(req.ExpMinutes) * time.Minute)

	claims := jwt.MapClaims{
		"iss": issuerURL,
		"sub": req.Sub,
		"aud": []string{req.Aud},
		"iat": now.Unix(),
		"exp": expiry.Unix(),
	}

	token := jwt.NewWithClaims(jwt.SigningMethodRS512, claims)
	token.Header["kid"] = "demo-key-1"

	signed, err := token.SignedString(privateKey)
	if err != nil {
		http.Error(w, fmt.Sprintf("signing error: %v", err), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(TokenResponse{
		AccessToken: signed,
		ExpiresIn:   req.ExpMinutes * 60,
		TokenType:   "Bearer",
	})
}
