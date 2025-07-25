package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

var (
	configDir string
	logDir    string
	upgrader  = websocket.Upgrader{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		CheckOrigin:     func(r *http.Request) bool { return true },
	}
	services = []string{"dashboard", "frps", "sshd", "traefik", "xray"}
)

type ServiceStatus struct {
	Name      string `json:"name"`
	Status    string `json:"status"`
	Timestamp string `json:"timestamp"`
}

type ConfigFile struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	Content string `json:"content"`
}

type APIResponse struct {
	Status  string      `json:"status"`
	Message string      `json:"message,omitempty"`
	Data    interface{} `json:"data,omitempty"`
}

func main() {
	flag.StringVar(&configDir, "config-dir", "/data/config", "Directory for configuration files")
	flag.StringVar(&logDir, "log-dir", "/data/logs", "Directory for log files")
	flag.Parse()

	log.Printf("Starting Admin Dashboard. Config Dir: %s, Log Dir: %s", configDir, logDir)

	gin.SetMode(gin.ReleaseMode)
	router := gin.Default()

	// Basic Auth Middleware
	auth := gin.BasicAuth(gin.Accounts{
		os.Getenv("DASHBOARD_USER"): os.Getenv("DASHBOARD_PWD"),
	})

	// Serve static files (HTML, CSS, JS)
	router.Static("/static", "./static")
	router.GET("/", func(c *gin.Context) {
		c.File("./static/index.html")
	})

	api := router.Group("/api", auth)
	{
		// Service Management
		api.GET("/services", handleGetServices)
		api.POST("/services/:name/:action", handleServiceAction)

		// Log Management
		api.GET("/logs/:service", handleGetLogs)

		// Config Management
		api.GET("/configs", handleGetConfigs)
		api.POST("/configs", handleUpdateConfig)

		// Web Terminal
		api.GET("/ws/tty", func(c *gin.Context) {
			handleTTY(c.Writer, c.Request)
		})
	}

	// Health check endpoint
	router.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})
	
	log.Println("Admin Dashboard listening on :8080")
	if err := router.Run(":8080"); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}

// --- Handlers ---

func handleGetServices(c *gin.Context) {
	var statuses []ServiceStatus
	var wg sync.WaitGroup
	var mu sync.Mutex
	for _, service := range services {
		wg.Add(1)
		go func(s string) {
			defer wg.Done()
			cmd := exec.Command("s6-svstat", "-o", "up,ready", filepath.Join("/var/run/s6/services", s))
			output, err := cmd.CombinedOutput()
			
			status := "down"
			if err == nil {
				if strings.Contains(string(output), "up") && strings.Contains(string(output), "ready") {
					status = "up"
				}
			}

			mu.Lock()
			statuses = append(statuses, ServiceStatus{
				Name:      s,
				Status:    status,
				Timestamp: time.Now().Format(time.RFC3339),
			})
			mu.Unlock()
		}(service)
	}
	wg.Wait()
	c.JSON(http.StatusOK, APIResponse{Status: "success", Data: statuses})
}

func handleServiceAction(c *gin.Context) {
	service := c.Param("name")
	action := c.Param("action")

	var s6_action string
	switch action {
	case "start":
		s6_action = "-u" // up
	case "stop":
		s6_action = "-d" // down
	case "restart":
		s6_action = "-t" // term
	default:
		c.JSON(http.StatusBadRequest, APIResponse{Status: "error", Message: "Invalid action"})
		return
	}

	cmd := exec.Command("s6-svc", s6_action, filepath.Join("/var/run/s6/services", service))
	if err := cmd.Run(); err != nil {
		c.JSON(http.StatusInternalServerError, APIResponse{Status: "error", Message: fmt.Sprintf("Failed to %s service: %v", action, err)})
		return
	}

	c.JSON(http.StatusOK, APIResponse{Status: "success", Message: fmt.Sprintf("Service %s action '%s' triggered.", service, action)})
}

func handleGetLogs(c *gin.Context) {
	service := c.Param("service")
	logFile := filepath.Join(logDir, service+".log")
	if service == "dashboard" {
		c.JSON(http.StatusBadRequest, APIResponse{Status: "error", Message: "Cannot stream dashboard logs via this endpoint."})
		return
	}

	c.Writer.Header().Set("Content-Type", "text/event-stream")
	c.Writer.Header().Set("Cache-Control", "no-cache")
	c.Writer.Header().Set("Connection", "keep-alive")

	cmd := exec.Command("tail", "-F", "-n", "100", logFile)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to create pipe"})
		return
	}

	if err := cmd.Start(); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to start tail"})
		return
	}
	
	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		fmt.Fprintf(c.Writer, "data: %s\n\n", scanner.Text())
		c.Writer.Flush()
	}

	cmd.Wait()
}


func handleGetConfigs(c *gin.Context) {
	configFiles := map[string]string{
		"frps":    "frps.toml",
		"xray":    "xray.json",
		"traefik": "traefik/dynamic.yml",
	}

	var configs []ConfigFile
	for name, path := range configFiles {
		fullPath := filepath.Join(configDir, path)
		content, err := os.ReadFile(fullPath)
		if err != nil {
			c.JSON(http.StatusInternalServerError, APIResponse{Status: "error", Message: fmt.Sprintf("Failed to read config %s: %v", name, err)})
			return
		}
		configs = append(configs, ConfigFile{
			Name:    name,
			Path:    path,
			Content: string(content),
		})
	}
	c.JSON(http.StatusOK, APIResponse{Status: "success", Data: configs})
}

func handleUpdateConfig(c *gin.Context) {
	var req ConfigFile
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, APIResponse{Status: "error", Message: "Invalid request body"})
		return
	}

	fullPath := filepath.Join(configDir, req.Path)
	// Security check to prevent path traversal
	if !strings.HasPrefix(fullPath, configDir) {
		c.JSON(http.StatusBadRequest, APIResponse{Status: "error", Message: "Invalid config path"})
		return
	}

	if err := os.WriteFile(fullPath, []byte(req.Content), 0644); err != nil {
		c.JSON(http.StatusInternalServerError, APIResponse{Status: "error", Message: fmt.Sprintf("Failed to write config file: %v", err)})
		return
	}

	c.JSON(http.StatusOK, APIResponse{Status: "success", Message: "Configuration updated successfully."})
}

func handleTTY(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("Failed to upgrade websocket: %v", err)
		return
	}
	defer conn.Close()

	cmd := exec.Command("/bin/bash", "-l")
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")

	ptmx, err := pty.Start(cmd)
	if err != nil {
		log.Printf("Failed to start pty: %v", err)
		return
	}
	defer func() { _ = ptmx.Close() }()

	// Handle resizing
	go func() {
		for {
			_, msg, err := conn.ReadMessage()
			if err != nil {
				return
			}
			var size struct{ Cols, Rows uint16 }
			if err := json.Unmarshal(msg, &size); err == nil && size.Cols > 0 && size.Rows > 0 {
				_ = pty.Setsize(ptmx, &pty.Winsize{Rows: size.Rows, Cols: size.Cols})
			}
		}
	}()
	
	// PTY -> WebSocket
	go func() {
		buf := make([]byte, 1024)
		for {
			n, err := ptmx.Read(buf)
			if err != nil {
				conn.Close()
				return
			}
			if err := conn.WriteMessage(websocket.BinaryMessage, buf[:n]); err != nil {
				return
			}
		}
	}()

	// WebSocket -> PTY
	for {
		_, reader, err := conn.NextReader()
		if err != nil {
			return
		}
		if _, err := io.Copy(ptmx, reader); err != nil {
			return
		}
	}
}
