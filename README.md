# Host Your CV on AWS (23L-3080)

Region: ap-southeast-2. Bucket: `cv-23l-3080`.
- EC2 site: http://54.252.248.183 (instance `i-06434de6876242992`)
- Lambda site: https://6hxmo3fpoeuq6emhb7mbovlgy40gnthm.lambda-url.ap-southeast-2.on.aws/

## Architecture

```
                        +-----------------------------+
                        |  S3 bucket cv-23l-3080      |
                        |  (private, versioned)       |
                        |  site/index.html style.css  |
                        |       cv.pdf                |
                        +--------------+--------------+
                    GetObject/ListBucket |        | GetObject
               (EC2 role, via sync)      |        | (Lambda role)
                        +----------------+        +----------------+
                        |                                          |
              +---------v----------+                  +------------v-----------+
              | EC2 t3.micro       |                  | Lambda function        |
              | httpd + systemd    |                  | python3.14, URL (NONE) |
              | timer (every 2min) |                  +------------+-----------+
              +---------+----------+                               |
                        | HTTP :80                                 | HTTPS
                     Visitor                                    Visitor
```

**Path A (EC2):** A visitor's request on port 80 reaches Apache on the instance, which serves files that `sync-cv.sh` copied from the private bucket using the instance role. A systemd timer re-runs the sync every 2 minutes and fills in the `Hosted on` footer with the instance ID.

**Path B (Lambda):** A visitor's HTTPS request goes to the public function URL, which invokes the function. The function reads the file from the private bucket with its role, fills in the footer and returns it (the PDF is base64 encoded).

The function URL was created with the AWS CLI instead of the console, so I added the two permission statements (`lambda:InvokeFunctionUrl` and `lambda:InvokeFunction` via function URL) myself.

## Access denied from the instance (section 4)

```
$ aws s3 rm s3://cv-23l-3080/site/index.html
delete failed: s3://cv-23l-3080/site/index.html An error occurred (AccessDenied) when calling the DeleteObject operation: User: arn:aws:sts::575220276219:assumed-role/cv-ec2-role-23l-3080/i-06434de6876242992 is not authorized to perform: s3:DeleteObject on resource: "arn:aws:s3:::cv-23l-3080/site/index.html" because no identity-based policy allows the s3:DeleteObject action

$ aws s3 cp /etc/hostname s3://cv-23l-3080/site/index.html
upload failed: ../../etc/hostname to s3://cv-23l-3080/site/index.html An error occurred (AccessDenied) when calling the PutObject operation: User: arn:aws:sts::575220276219:assumed-role/cv-ec2-role-23l-3080/i-06434de6876242992 is not authorized to perform: s3:PutObject on resource: "arn:aws:s3:::cv-23l-3080/site/index.html" because no identity-based policy allows the s3:PutObject action
```

## Last 10 lines of /var/log/cv-sync.log

```
2026-10-24T12:05:33Z sync OK instance=i-06434de6876242992
2026-10-24T12:07:33Z sync OK instance=i-06434de6876242992
2026-10-24T12:09:33Z sync OK instance=i-06434de6876242992
2026-10-24T12:11:33Z sync OK instance=i-06434de6876242992
2026-10-24T12:13:34Z sync OK instance=i-06434de6876242992
2026-10-24T12:15:34Z sync OK instance=i-06434de6876242992
2026-10-24T12:17:34Z sync OK instance=i-06434de6876242992
2026-10-24T12:19:34Z sync OK instance=i-06434de6876242992
2026-10-24T12:21:34Z sync OK instance=i-06434de6876242992
2026-10-24T12:23:34Z sync OK instance=i-06434de6876242992
```

## Written answers

1. **Roles instead of keys.** A role gives the instance or function short-lived credentials that AWS creates and rotates automatically, so there is nothing to store, copy or forget about. Keys in the user data would stay readable on the instance and to anyone with access to the instance's settings. They never expire on their own, and anyone who found them (or a copy in git) could use them from anywhere until someone noticed and deactivated them.

2. **Opening the S3 address directly.** They see an XML "Access Denied" page (HTTP 403). It happens because all four Block Public Access settings are on and the bucket has no public policy or ACL, so a request without a signature is refused.

3. **The function URL permission.** The resource-based policy on the function says that any principal (`*`) may call it, as long as the URL's auth type is NONE, so no AWS signature is needed. This is acceptable for the function because my code decides what is returned: it only serves three fixed files and a 404 page, and its role can only read `site/`. A public bucket would let anyone fetch or list any object directly without going through my code, and it would stop me controlling what is shared.

4. **Comparing the paths.** When nobody visits, the EC2 path still costs money while the instance runs (instance hours, its disk and its public IPv4 address), whereas Lambda costs almost nothing, apart from tiny S3 and log storage. If traffic grew a hundred times, the single t3.micro would slow down or fail unless I resized it or added more instances behind a load balancer. Lambda scales on its own by running more copies, and its bill grows with the number of requests.

5. **Deleting the instance.** I lose the server itself, its disk, the local copy of the site, the sync log and its public IP address, so the EC2 address stops working. I still have the bucket with all files and versions, both IAM roles, the security group, the Lambda site, and the scripts in the repository. That means I can launch a new instance with the same user data and it would sync the CV again, but it would have a new instance ID and a new IP.

## Sources and help used
(Write honestly what you used: course material, AWS documentation, and any AI assistance, and where you adapted code.)