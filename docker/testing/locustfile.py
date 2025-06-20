from locust import HttpUser, task, between

class DDCUser(HttpUser):
    wait_time = between(1, 3)
    
    @task(3)
    def health_check(self):
        """Test health endpoint"""
        self.client.get("/health")
    
    @task(2)
    def stats_check(self):
        """Test stats endpoint"""
        self.client.get("/stats")
    
    @task(1)
    def root_check(self):
        """Test root endpoint"""
        self.client.get("/")
    
    def on_start(self):
        """Called when a user starts"""
        self.client.get("/health") 
