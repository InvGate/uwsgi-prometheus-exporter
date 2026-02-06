"""
Simple WSGI application for testing the Prometheus metrics plugin.

This app has a few endpoints to generate different types of traffic.
"""

def application(env, start_response):
    path = env.get('PATH_INFO', '/')

    if path == '/':
        start_response('200 OK', [('Content-Type', 'text/plain')])
        return [b'Hello from test app\n']

    elif path == '/slow':
        # Simulate slow request
        import time
        time.sleep(0.1)
        start_response('200 OK', [('Content-Type', 'text/plain')])
        return [b'Slow response\n']

    elif path == '/error':
        # Simulate error
        start_response('500 Internal Server Error', [('Content-Type', 'text/plain')])
        return [b'Error response\n']

    else:
        start_response('404 Not Found', [('Content-Type', 'text/plain')])
        return [b'Not found\n']
