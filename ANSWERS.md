# Part 5 — Written Question

## Q1: Migrating from ingress-nginx to Gateway API with Zero Downtime

### How I would do it (Step-by-Step)
1. **Side-by-side setup:** Install the new Gateway controller on the cluster. It will spin up a new Load Balancer with a brand new external IP. Leave the old `ingress-nginx` controller running exactly as it is so live traffic is perfectly safe.
2. **Recreate the rules:** Write the new Gateway YAML files (`HTTPRoute`) for all 40 applications. Point them to the exact same backend K8s Services that the old Ingresses are using. 
3. **Test privately:** Before changing anything for the users, test the new Load Balancer IP locally (using `curl -H "Host: ..."` or changing `/etc/hosts`) to make sure the pages load and the SSL certificates are working properly.
4. **Gradual DNS update:** Go to the DNS provider (like Route 53) and change the records to point to the new IP. Do this in batches—start with internal tools, check the logs for errors, and move the main production websites last.
5. **Cleanup:** Wait 48 hours for DNS caches to clear globally. Once the old Nginx logs show zero traffic, delete the old `Ingress` files and uninstall Nginx.

### What is likely to break
* **Nginx annotations:** Any special rules in the old YAMLs like `nginx.ingress.../rewrite-target` or custom CORS headers won't work out of the box on the new Gateway and have to be manually figured out.
* **Large file uploads:** The new controller might have a smaller default limit for request sizes or shorter connection timeouts, which could cause 504 errors on uploads or long API calls.
* **SSL warnings:** With 40 different apps, it is easy to misconfigure which certificate goes to which domain on the new setup, which would throw browser privacy warnings for users.