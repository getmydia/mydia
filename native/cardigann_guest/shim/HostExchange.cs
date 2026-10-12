#if WASM_BUILD
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using CardigannWorld;
using CardigannWorld.wit.Imports.mydia.cardigann.v1_0_0;

namespace Mydia.CardigannGuest.Shim
{
    // The wasm build's IExchange: one call across the component boundary to the
    // host's http-request import. Host failures surface as HttpRequestException,
    // the type a socket failure produces, so upstream's own handling applies.
    public sealed class HostExchange : IExchange
    {
        public RawResponse Send(RawRequest request)
        {
            var headers = request.Headers
                .Select(h => new ITypesImports.Header(h.Name, h.Value))
                .ToList();
            var req = new ITypesImports.HttpReq(request.Method, request.Url, headers, request.Body);

            ITypesImports.HttpResp resp;
            try
            {
                resp = IHostImports.HttpRequest(req);
            }
            catch (WitException<ITypesImports.HttpError> e)
            {
                throw new HttpRequestException(Describe((ITypesImports.HttpError)e.Value));
            }

            var respHeaders = resp.headers.Select(h => (h.name, h.value)).ToArray();
            return new RawResponse(resp.status, respHeaders, resp.body);
        }

        private static string Describe(ITypesImports.HttpError error) => error.Tag switch
        {
            ITypesImports.HttpError.Tags.Timeout => "timeout: " + error.AsTimeout,
            ITypesImports.HttpError.Tags.Connect => "connect: " + error.AsConnect,
            ITypesImports.HttpError.Tags.Blocked => "blocked: " + error.AsBlocked,
            _ => "other: " + error.AsOther
        };
    }
}
#endif
