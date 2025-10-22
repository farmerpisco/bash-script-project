## Project Overview  

The goal was to:  
- Automate the deployment process using a Bash script (`deploy.sh`)  
- Containerize the application using Docker  
- Set up Nginx as a reverse proxy  
- Verify the deployment using health checks  

Inputs required includes: Git repository URL, Personal Access Token (PAT), Branch name, Remote Username, Remote server IP, SSH key path, and Application internal port.

You can run the script using ./deploy.sh


When successfully deployed, the app becomes accessible via the public IP and port — showing the calculator interface in your browser.  

---

## Tech Stack  

- HTML, CSS, JavaScript – Calculator frontend  
- Docker – Containerization  
- Nginx – Reverse proxy configuration  
- Bash – Deployment automation  
- AWS EC2 (Ubuntu) – Hosting environment  

---

## Project Structure  

```bash
├── app (Altschool Assessment)/
│   ├── index.html
│   ├── style.css
│   ├── index.js
│   ├── Dockerfile

├── deploy.sh
└── README.md
