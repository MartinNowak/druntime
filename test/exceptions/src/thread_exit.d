import core.atomic, core.thread, core.stdc.stdio;

enum N = 10;
shared uint val;

void run()
{
    foreach (_; 0 .. N)
    {
        if (atomicOp!"+="(val, 1) > N/2)
            throw new Error("Thread has an error.");
    }
}

void main()
{
    auto thr = new Thread({
                run();
    }).start();
    while (atomicLoad(val) < N)
        Thread.yield();
    thr.join();
}
