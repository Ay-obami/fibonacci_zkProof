pragma circom 2.0.6;

function fibtest(fib1, fib2, n) {
    var a = fib1;
    var b = fib2;
    var c;

    //compute Fibonacci
    for (var i=0; i < n; i++) {
        c = a + b;
        a = b;
        b = c;
    }
    return c;
}