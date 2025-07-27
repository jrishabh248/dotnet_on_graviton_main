using GadgetsOnline.Services;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Web;
using Microsoft.AspNetCore.Mvc;
using System.Net.Http;

namespace GadgetsOnline.Controllers
{
    public class HomeController : Controller
    {
        Inventory inventory;
        public ActionResult Index()
        {
            inventory = new Inventory();
            var products = inventory.GetBestSellers(6);
            ViewBag.Hostname = "; Node: " + GetMetadataValue("hostname");
            ViewBag.AvailabilityZone = "; AZ: " + GetMetadataValue("placement/availability-zone");
            ViewBag.InstanceType = "; Instance-Type: " + GetMetadataValue("instance-type");
            return View(products);
        }

        private static readonly Dictionary<string, string> metadataCache = new Dictionary<string, string>();
        private static string GetMetadataValue(string path)
        {
            if (!metadataCache.ContainsKey(path))
            {
                using (var httpClient = new HttpClient())
                {
                    try
                    {
                        // Get IMDSv2 token
                        var tokenRequest = new HttpRequestMessage(HttpMethod.Put, "http://169.254.169.254/latest/api/token");
                        tokenRequest.Headers.Add("X-aws-ec2-metadata-token-ttl-seconds", "21600");
                        var tokenResponse = httpClient.SendAsync(tokenRequest).Result;
                        
                        if (tokenResponse.IsSuccessStatusCode)
                        {
                            var token = tokenResponse.Content.ReadAsStringAsync().Result;
                            
                            // Use token to get metadata
                            var metadataRequest = new HttpRequestMessage(HttpMethod.Get, $"http://169.254.169.254/latest/meta-data/{path}");
                            metadataRequest.Headers.Add("X-aws-ec2-metadata-token", token);
                            var response = httpClient.SendAsync(metadataRequest).Result;
                            
                            if (response.IsSuccessStatusCode)
                            {
                                var metadataValue = response.Content.ReadAsStringAsync().Result;
                                metadataCache[path] = metadataValue;
                            }
                            else
                            {
                                metadataCache[path] = "Unknown";
                            }
                        }
                        else
                        {
                            metadataCache[path] = "Token Error";
                        }
                    }
                    catch
                    {
                        metadataCache[path] = "Error";
                    }
                }
            }

            return metadataCache[path];
        }

        public ActionResult About()
        {
            ViewBag.Message = "Your application description page.";
            return View();
        }

        public ActionResult Contact()
        {
            ViewBag.Message = "Your contact page.";
            return View();
        }
    }
}
